#!/usr/bin/env bash
set -euo pipefail

DEFAULT_GKE_REGION="us-central1"
DEFAULT_GKE_CLUSTER_NAME="devspace-starter-pack"
DEFAULT_GKE_DNS_DOMAIN="gcp.kube"
DEFAULT_GKE_DNS_ZONE_NAME="gcp-kube"
DEFAULT_GKE_GATEWAY_NAMESPACE="gke-gateway"
DEFAULT_GKE_PROTECTION="iap"
DEFAULT_GKE_GCLOUD_CONFIGURATION="devspace-starter-pack"
DEFAULT_DEV_REGISTRY_REPOSITORY="devspace-dev"
LOCAL_CONTEXT_REGEX='^(kind(-.*)?|docker-desktop|minikube|rancher-desktop|microk8s)$'
GKE_TERRAFORM_DIR="infra/gcp-ephemeral"
CLUSTER_ENV_NAMESPACE="devspace-system"
CLUSTER_ENV_CONFIGMAP="devspace-starter-pack-env"

load_devspace_vars() {
  CLUSTER_PROVIDER="${CLUSTER_PROVIDER:-}"
  GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-istio-ingress}"
  GATEWAY_PROVIDER="${GATEWAY_PROVIDER:-local-istio}"
  DNS_DOMAIN="${DNS_DOMAIN:-int.kube}"
  DNS_MODE="${DNS_MODE:-local}"
  DNS_SERVICE_ID="${DNS_SERVICE_ID:-kube}"
  GKE_PROJECT_ID="${GKE_PROJECT_ID:-}"
  GKE_REGION="${GKE_REGION:-${DEFAULT_GKE_REGION}}"
  GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-}"
  GKE_KUBE_CONTEXT="${GKE_KUBE_CONTEXT:-}"
  GKE_DNS_DOMAIN="${GKE_DNS_DOMAIN:-${DEFAULT_GKE_DNS_DOMAIN}}"
  GKE_DNS_NAMESERVERS="${GKE_DNS_NAMESERVERS:-}"
  GKE_SELECTED_CONTEXT="${GKE_SELECTED_CONTEXT:-}"
  GKE_PROTECTION="${GKE_PROTECTION:-${DEFAULT_GKE_PROTECTION}}"
  GKE_GCLOUD_CONFIGURATION="${GKE_GCLOUD_CONFIGURATION:-${DEFAULT_GKE_GCLOUD_CONFIGURATION}}"
  GKE_GCLOUD_ACCOUNT="${GKE_GCLOUD_ACCOUNT:-}"
  GKE_IAP_ACCESSOR_MEMBERS="${GKE_IAP_ACCESSOR_MEMBERS:-}"
  GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:-}"
  GCP_ORG_ID="${GCP_ORG_ID:-}"
  GCP_FOLDER_ID="${GCP_FOLDER_ID:-}"
  DEV_REGISTRY_HOST="${DEV_REGISTRY_HOST:-}"
  DEV_REGISTRY="${DEV_REGISTRY:-}"
  DEV_REGISTRY_IMAGE_PREFIX="${DEV_REGISTRY_IMAGE_PREFIX:-}"
  DEV_REGISTRY_REPOSITORY="${DEV_REGISTRY_REPOSITORY:-${DEFAULT_DEV_REGISTRY_REPOSITORY}}"
  DEV_REGISTRY_WRITER_MEMBERS="${DEV_REGISTRY_WRITER_MEMBERS:-}"
  CONFIG_CONNECTOR_ENABLED="${CONFIG_CONNECTOR_ENABLED:-false}"
  CONFIG_CONNECTOR_MODE="${CONFIG_CONNECTOR_MODE:-}"
  CONFIG_CONNECTOR_PROJECT_ID="${CONFIG_CONNECTOR_PROJECT_ID:-}"
  CONFIG_CONNECTOR_SERVICE_ACCOUNT="${CONFIG_CONNECTOR_SERVICE_ACCOUNT:-}"
  DEVSPACE_NAMESPACE="${DEVSPACE_NAMESPACE:-}"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo >&2 "E: Required command not found: $1"
    exit 1
  fi
}

require_value() {
  local name="$1"
  local value="$2"
  local hint="$3"
  if [[ -z "${value}" ]]; then
    echo >&2 "E: ${name} is required. ${hint}"
    exit 1
  fi
}

is_empty_marker() {
  case "${1:-}" in
    ""|"<nil>"|"null") return 0 ;;
    *) return 1 ;;
  esac
}

generate_managed_project_id() {
  local suffix
  suffix="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  printf 'devspace-gke-%s\n' "${suffix}"
}

tfvar_string() {
  local key="$1"
  local file="$2"
  awk -v key="${key}" '
    $1 == key && $2 == "=" {
      value = $0
      sub("^[^=]*= *", "", value)
      sub(" *#.*$", "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "${file}"
}

tfvar_string_list_csv() {
  local key="$1"
  local file="$2"
  awk -v key="${key}" '
    $1 == key && $2 == "=" && $3 == "[" {in_list = 1; next}
    in_list && $0 ~ /\]/ {exit}
    in_list {
      value = $0
      sub(" *#.*$", "", value)
      gsub(/[",]/, "", value)
      gsub(/^ *| *$/, "", value)
      if (value != "") {
        if (seen) {
          printf ","
        }
        printf "%s", value
        seen = 1
      }
    }
  ' "${file}"
}

current_context() {
  kubectl config current-context 2>/dev/null || true
}

current_namespace() {
  kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || true
}

select_context_preserving_namespace() {
  local context="$1"
  local previous_namespace="${2:-}"
  local active_context

  active_context="$(current_context)"
  if [[ "${active_context}" != "${context}" ]]; then
    kubectl config use-context "${context}" >/dev/null
    devspace use context "${context}"
  fi

  if [[ -n "${previous_namespace}" ]]; then
    kubectl config set-context "${context}" --namespace="${previous_namespace}" >/dev/null
  fi
}

provider_from_context() {
  local context="$1"
  if [[ "${context}" == gke_* ]]; then
    printf 'gke'
    return
  fi
  if [[ "${context}" =~ ${LOCAL_CONTEXT_REGEX} ]]; then
    printf 'local'
    return
  fi
  printf ''
}

context_field() {
  local context="$1"
  local field="$2"
  printf '%s' "${context}" | cut -d_ -f"${field}"
}

context_project() {
  context_field "$1" 2
}

context_region() {
  context_field "$1" 3
}

context_cluster() {
  context_field "$1" 4
}

require_supported_context() {
  local context provider
  context="$(current_context)"
  if [[ -z "${context}" ]]; then
    echo >&2 "E: No current Kubernetes context is selected."
    exit 1
  fi

  provider="$(provider_from_context "${context}")"
  if [[ -z "${provider}" ]]; then
    echo >&2 "E: Unsupported Kubernetes context ${context}; expected a GKE context or a local context."
    exit 1
  fi

  printf '%s\n' "${provider}"
}

validate_provider_override() {
  local derived_provider="$1"
  local requested_provider="${CLUSTER_PROVIDER:-}"
  if [[ -n "${requested_provider}" && "${requested_provider}" != "${derived_provider}" ]]; then
    echo >&2 "E: CLUSTER_PROVIDER=${requested_provider} does not match current Kubernetes context provider ${derived_provider}."
    exit 1
  fi
}

gke_gateway_namespace() {
  local namespace="${GATEWAY_NAMESPACE:-}"
  if [[ -z "${namespace}" || "${namespace}" == "istio-ingress" ]]; then
    namespace="${DEFAULT_GKE_GATEWAY_NAMESPACE}"
  fi
  printf '%s\n' "${namespace}"
}

terraform_output_json() {
  terraform -chdir="${GKE_TERRAFORM_DIR}" output -json 2>/dev/null || true
}

tf_output_value() {
  local tf_output="$1"
  local output_name="$2"
  if [[ -z "${tf_output}" ]]; then
    return
  fi
  printf '%s' "${tf_output}" | yq -r ".${output_name}.value // \"\"" || true
}

tf_state_value() {
  local resource="$1"
  local key="$2"
  { terraform -chdir="${GKE_TERRAFORM_DIR}" state show -no-color "${resource}" 2>/dev/null || true; } |
    awk -v key="${key}" '
      $1 == key && $2 == "=" {
        value = $0
        sub("^[^=]*= *", "", value)
        sub(" *#.*$", "", value)
        gsub(/^"|"$/, "", value)
        print value
        exit
      }
    '
}

managed_project_in_state() {
  terraform -chdir="${GKE_TERRAFORM_DIR}" state show -no-color google_project.ephemeral >/dev/null 2>&1
}

terraform_outputs_match_context() {
  local tf_output="$1"
  local context="$2"
  [[ -n "${tf_output}" ]] || return 1
  [[ "${context}" == gke_*_*_* ]] || return 1

  local project region cluster
  project="$(tf_output_value "${tf_output}" project_id)"
  region="$(tf_output_value "${tf_output}" region)"
  cluster="$(tf_output_value "${tf_output}" cluster_name)"

  [[ -n "${project}" && -n "${region}" && -n "${cluster}" ]] || return 1
  [[ "${project}" == "$(context_project "${context}")" &&
     "${region}" == "$(context_region "${context}")" &&
     "${cluster}" == "$(context_cluster "${context}")" ]]
}

terraform_context_name() {
  local tf_output="$1"
  local project region cluster
  project="$(tf_output_value "${tf_output}" project_id)"
  region="$(tf_output_value "${tf_output}" region)"
  cluster="$(tf_output_value "${tf_output}" cluster_name)"
  [[ -n "${project}" && -n "${region}" && -n "${cluster}" ]] || return 1
  printf 'gke_%s_%s_%s\n' "${project}" "${region}" "${cluster}"
}

default_iap_accessor_member() {
  local account
  account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1 || true)"
  if [[ -z "${account}" ]]; then
    return 1
  fi

  if [[ "${account}" == *gserviceaccount.com ]]; then
    printf 'serviceAccount:%s\n' "${account}"
    return
  fi
  printf 'user:%s\n' "${account}"
}

gcloud_config_value() {
  local value
  value="$(gcloud config get-value "$1" 2>/dev/null || true)"
  if [[ "${value}" == "(unset)" ]]; then
    value=""
  fi
  printf '%s' "${value}"
}

gcloud_configuration_exists() {
  gcloud config configurations describe "$1" >/dev/null 2>&1
}

gcloud_cli_auth_valid() {
  local account="$1"
  [[ -n "${account}" ]] || return 1
  gcloud auth print-access-token --account "${account}" >/dev/null 2>&1
}

gcloud_adc_valid() {
  gcloud auth application-default print-access-token >/dev/null 2>&1
}

gcloud_login_command() {
  local account="$1"
  if [[ -n "${account}" ]]; then
    printf 'gcloud auth login %s --update-adc' "${account}"
  else
    printf 'gcloud auth login --update-adc'
  fi
}

ensure_gcloud_auth() {
  local project_id="${1:-}"
  local config_name="${GKE_GCLOUD_CONFIGURATION:-${DEFAULT_GKE_GCLOUD_CONFIGURATION}}"
  local account="${GKE_GCLOUD_ACCOUNT:-}"

  if [[ -z "${account}" ]]; then
    account="$(gcloud_config_value account)"
  fi

  if ! gcloud_configuration_exists "${config_name}"; then
    echo >&2 "I: Creating gcloud configuration ${config_name}..."
    gcloud config configurations create "${config_name}" --quiet >/dev/null
  fi
  gcloud config configurations activate "${config_name}" --quiet >/dev/null

  if [[ -n "${account}" ]]; then
    gcloud config set account "${account}" --quiet >/dev/null
  fi

  if ! gcloud_cli_auth_valid "${account}" || ! gcloud_adc_valid; then
    if [[ ! -t 0 ]]; then
      echo >&2 "E: GKE setup requires valid gcloud CLI auth and Application Default Credentials."
      echo >&2 "I: Run: $(gcloud_login_command "${account}")"
      echo >&2 "I: Then retry: devspace --var CLUSTER_PROVIDER=gke run ensure-cluster"
      exit 1
    fi

    echo >&2 "I: Starting Google Cloud login for DevSpace GKE setup..."
    echo >&2 "I: This refreshes both gcloud CLI credentials and Application Default Credentials."
    if [[ -n "${account}" ]]; then
      gcloud auth login "${account}" --update-adc
    else
      gcloud auth login --update-adc
    fi

    account="$(gcloud_config_value account)"
    require_value "gcloud account" "${account}" "Google Cloud login did not select an account."
    gcloud config set account "${account}" --quiet >/dev/null
  fi

  if ! gcloud_cli_auth_valid "${account}"; then
    echo >&2 "E: gcloud CLI credentials for ${account} are still invalid."
    echo >&2 "I: Run: $(gcloud_login_command "${account}")"
    exit 1
  fi
  if ! gcloud_adc_valid; then
    echo >&2 "E: Google Application Default Credentials are missing or expired."
    echo >&2 "I: Run: $(gcloud_login_command "${account}")"
    exit 1
  fi

  if [[ -n "${project_id}" ]]; then
    gcloud config set project "${project_id}" --quiet >/dev/null
  fi
}

resource_id() {
  local value="$1"
  printf '%s' "${value##*/}"
}

print_candidates() {
  local title="$1"
  shift

  [[ "$#" -gt 0 ]] || return
  echo >&2 "I: ${title}:"
  local candidate
  for candidate in "$@"; do
    echo >&2 "I:   ${candidate}"
  done
}

discover_billing_account_id() {
  local output
  if ! output="$(gcloud billing accounts list --filter='open=true' --format='value(name,displayName)' 2>&1)"; then
    echo >&2 "E: Could not list visible open billing accounts."
    printf '%s\n' "${output}" >&2
    echo >&2 "I: Run: devspace set var GCP_BILLING_ACCOUNT_ID=BILLING_ACCOUNT_ID"
    exit 1
  fi

  local -a ids=()
  local -a candidates=()
  local name display id
  while IFS=$'\t' read -r name display; do
    [[ -n "${name}" ]] || continue
    id="$(resource_id "${name}")"
    ids+=("${id}")
    if [[ -n "${display}" ]]; then
      candidates+=("${id} (${display})")
    else
      candidates+=("${id}")
    fi
  done <<< "${output}"

  case "${#ids[@]}" in
    1)
      printf '%s' "${ids[0]}"
      ;;
    0)
      echo >&2 "E: No visible open GCP billing accounts were found for the active gcloud account."
      echo >&2 "I: Run: devspace set var GCP_BILLING_ACCOUNT_ID=BILLING_ACCOUNT_ID"
      exit 1
      ;;
    *)
      echo >&2 "E: Multiple visible open GCP billing accounts were found; choose one explicitly."
      print_candidates "Visible open billing accounts" "${candidates[@]}"
      echo >&2 "I: Run: devspace set var GCP_BILLING_ACCOUNT_ID=BILLING_ACCOUNT_ID"
      exit 1
      ;;
  esac
}

discover_org_id() {
  local output
  if ! output="$(gcloud organizations list --format='value(name,displayName)' 2>&1)"; then
    echo >&2 "E: Could not list visible GCP organizations."
    printf '%s\n' "${output}" >&2
    echo >&2 "I: Run: devspace set var GCP_ORG_ID=ORGANIZATION_ID"
    echo >&2 "I: Or run: devspace set var GCP_FOLDER_ID=FOLDER_ID"
    exit 1
  fi

  local -a ids=()
  local -a candidates=()
  local name display id
  while IFS=$'\t' read -r name display; do
    [[ -n "${name}" ]] || continue
    id="$(resource_id "${name}")"
    ids+=("${id}")
    if [[ -n "${display}" ]]; then
      candidates+=("${id} (${display})")
    else
      candidates+=("${id}")
    fi
  done <<< "${output}"

  case "${#ids[@]}" in
    1)
      printf '%s' "${ids[0]}"
      ;;
    0)
      echo >&2 "E: No visible GCP organizations were found for the active gcloud account."
      echo >&2 "I: Run: devspace set var GCP_ORG_ID=ORGANIZATION_ID"
      echo >&2 "I: Or run: devspace set var GCP_FOLDER_ID=FOLDER_ID"
      exit 1
      ;;
    *)
      echo >&2 "E: Multiple visible GCP organizations were found; choose an org or folder explicitly."
      print_candidates "Visible organizations" "${candidates[@]}"
      echo >&2 "I: Run: devspace set var GCP_ORG_ID=ORGANIZATION_ID"
      echo >&2 "I: Or run: devspace set var GCP_FOLDER_ID=FOLDER_ID"
      exit 1
      ;;
  esac
}

persist_discovered_var() {
  local name="$1"
  local value="$2"
  [[ -n "${value}" ]] || return
  devspace set var "${name}=${value}" >/dev/null
  echo >&2 "I: Persisted ${name}=${value}."
}

write_managed_tfvars() {
  local tfvars="$1"
  local billing_account_id="$2"
  local org_id="$3"
  local folder_id="$4"
  local region_value="$5"
  local project_id="$6"
  local dns_domain_value="$7"
  local writer_members="$8"
  local iap_accessor_members="$9"
  local config_connector_enabled="${10:-false}"
  local config_connector_iam_roles="${11:-}"

  {
    printf 'billing_account_id = "%s"\n' "${billing_account_id}"
    printf 'region = "%s"\n' "${region_value}"
    printf 'dns_domain = "%s."\n' "${dns_domain_value%.}"
    if [[ -n "${folder_id}" ]]; then
      printf 'folder_id = "%s"\n' "${folder_id}"
    elif [[ -n "${org_id}" ]]; then
      printf 'org_id = "%s"\n' "${org_id}"
    fi
    if [[ -n "${project_id}" ]]; then
      printf 'project_id = "%s"\n' "${project_id}"
    fi

    printf 'dev_registry_writer_members = [\n'
    write_hcl_string_list "${writer_members}"
    printf ']\n'

    printf 'iap_accessor_members = [\n'
    write_hcl_string_list "${iap_accessor_members}"
    printf ']\n'

    printf 'config_connector_enabled = %s\n' "${config_connector_enabled}"
    if [[ -n "${config_connector_iam_roles}" ]]; then
      printf 'config_connector_iam_roles = [\n'
      write_hcl_string_list "${config_connector_iam_roles}"
      printf ']\n'
    fi
  } > "${tfvars}"
}

write_hcl_string_list() {
  local csv="$1"
  local old_ifs="${IFS}"
  IFS=","
  local member
  for member in ${csv}; do
    member="$(printf '%s' "${member}" | sed 's/^ *//;s/ *$//')"
    if [[ -n "${member}" ]]; then
      printf '  "%s",\n' "${member}"
    fi
  done
  IFS="${old_ifs}"
}

ensure() {
  load_devspace_vars
  require_tool kubectl

  local requested_provider="${CLUSTER_PROVIDER:-}"
  local context context_provider provider
  context="$(current_context)"
  context_provider="$(provider_from_context "${context}")"

  if [[ -n "${requested_provider}" ]]; then
    provider="${requested_provider}"
  elif [[ -n "${context_provider}" ]]; then
    provider="${context_provider}"
  else
    if [[ -z "${context}" ]]; then
      echo >&2 "E: No current Kubernetes context is selected."
      echo >&2 "I: Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster' to create/select managed GKE."
    else
      echo >&2 "E: Unsupported Kubernetes context ${context}; expected a GKE context or a local context."
    fi
    exit 1
  fi

  case "${provider}" in
    local)
      ensure_local
      ;;
    gke)
      ensure_gke
      ;;
    *)
      echo >&2 "E: Unsupported CLUSTER_PROVIDER=${provider}; expected local or gke."
      exit 1
      ;;
  esac
}

ensure_local() {
  require_tool kubectl
  require_tool devspace

  local context provider
  context="$(current_context)"
  if [[ -z "${context}" ]]; then
    echo >&2 "E: No current Kubernetes context is selected."
    exit 1
  fi
  provider="$(provider_from_context "${context}")"
  if [[ "${provider}" != "local" ]]; then
    echo >&2 "E: Current Kubernetes context ${context} is not a supported local context."
    exit 1
  fi
  kubectl cluster-info >/dev/null

  echo >&2 "I: Selecting local cluster context ${context}..."
  DNS_MODE="local"
  DNS_SERVICE_ID="kube"
  DNS_DOMAIN="int.kube"
  GATEWAY_NAMESPACE="istio-ingress"
  GATEWAY_PROVIDER="local-istio"
  DEV_REGISTRY_HOST=""
  DEV_REGISTRY=""
  DEV_REGISTRY_IMAGE_PREFIX=""
  CONFIG_CONNECTOR_ENABLED="false"
  CONFIG_CONNECTOR_MODE=""
  CONFIG_CONNECTOR_PROJECT_ID=""
  CONFIG_CONNECTOR_SERVICE_ACCOUNT=""
  GKE_PROJECT_ID=""
  GKE_DNS_NAMESERVERS=""
  GKE_SELECTED_CONTEXT=""
  select_context_preserving_namespace "${context}" "$(current_namespace)"
  publish_cluster_env
  echo >&2 "I: Local cluster selected."
}

ensure_gke() {
  load_devspace_vars
  require_tool gcloud
  require_tool kubectl
  require_tool devspace
  require_tool terraform
  require_tool yq

  local context context_provider tf_output
  context="$(current_context)"
  context_provider="$(provider_from_context "${context}")"
  tf_output="$(terraform_output_json)"

  if [[ "${context_provider}" == "gke" ]]; then
    if terraform_outputs_match_context "${tf_output}" "${context}"; then
      echo >&2 "I: GKE context ${context} matches Terraform state; converging managed GKE."
      ensure_gke_managed
    else
      echo >&2 "I: GKE context ${context} does not match Terraform state; selecting as external GKE."
      ensure_gke_external "${context}"
    fi
    return
  fi

  echo >&2 "I: No active GKE context selected; converging managed GKE."
  ensure_gke_managed
}

ensure_gke_managed() {
  local tfvars="${GKE_TERRAFORM_DIR}/terraform.tfvars"
  local billing_account_id="${GCP_BILLING_ACCOUNT_ID:-}"
  local org_id="${GCP_ORG_ID:-}"
  local folder_id="${GCP_FOLDER_ID:-}"
  local region_value="${GKE_REGION:-${DEFAULT_GKE_REGION}}"
  local project_id="${GKE_PROJECT_ID:-}"
  local dns_domain_value="${GKE_DNS_DOMAIN:-${DEFAULT_GKE_DNS_DOMAIN}}"
  local writer_members="${DEV_REGISTRY_WRITER_MEMBERS:-}"
  local iap_accessor_members="${GKE_IAP_ACCESSOR_MEMBERS:-}"
  local config_connector_iam_roles=""
  local config_connector_enabled="${CONFIG_CONNECTOR_ENABLED:-false}"
  local gke_protection="${GKE_PROTECTION:-${DEFAULT_GKE_PROTECTION}}"
  local has_managed_project_state="false"

  if is_empty_marker "${project_id}"; then
    project_id=""
  fi

  if managed_project_in_state; then
    has_managed_project_state="true"
  fi

  if [[ -f "${tfvars}" ]]; then
    local tfvars_project_id
    tfvars_project_id="$(tfvar_string project_id "${tfvars}")"
    [[ -n "${billing_account_id}" ]] || billing_account_id="$(tfvar_string billing_account_id "${tfvars}")"
    if [[ -z "${project_id}" && "${has_managed_project_state}" == "true" ]]; then
      project_id="${tfvars_project_id}"
      if is_empty_marker "${project_id}"; then
        project_id=""
      fi
    elif [[ -z "${project_id}" ]] && ! is_empty_marker "${tfvars_project_id}"; then
      echo >&2 "I: Ignoring stale terraform.tfvars project_id because no managed Terraform state exists."
    fi
    [[ -n "${writer_members}" ]] || writer_members="$(tfvar_string_list_csv dev_registry_writer_members "${tfvars}")"
    [[ -n "${iap_accessor_members}" ]] || iap_accessor_members="$(tfvar_string_list_csv iap_accessor_members "${tfvars}")"
    if [[ "${config_connector_enabled}" != "true" ]]; then
      config_connector_enabled="$(tfvar_string config_connector_enabled "${tfvars}")"
    fi
    [[ -n "${config_connector_iam_roles}" ]] || config_connector_iam_roles="$(tfvar_string_list_csv config_connector_iam_roles "${tfvars}")"
    [[ -n "${org_id}" ]] || org_id="$(tfvar_string org_id "${tfvars}")"
    [[ -n "${folder_id}" ]] || folder_id="$(tfvar_string folder_id "${tfvars}")"
  fi
  if [[ "${config_connector_enabled}" != "true" ]]; then
    config_connector_enabled="false"
  fi

  require_value "GKE_REGION" "${region_value}" "Default should be ${DEFAULT_GKE_REGION}."

  ensure_gcloud_auth ""

  if [[ -z "${billing_account_id}" ]]; then
    billing_account_id="$(discover_billing_account_id)"
    persist_discovered_var GCP_BILLING_ACCOUNT_ID "${billing_account_id}"
  fi
  if [[ -z "${folder_id}" && -z "${org_id}" ]]; then
    org_id="$(discover_org_id)"
    persist_discovered_var GCP_ORG_ID "${org_id}"
  fi

  require_value "GCP_BILLING_ACCOUNT_ID" "${billing_account_id}" "Set it with 'devspace set var GCP_BILLING_ACCOUNT_ID=...'."
  if [[ -z "${folder_id}" && -z "${org_id}" ]]; then
    echo >&2 "E: Set GCP_ORG_ID or GCP_FOLDER_ID before running managed GKE setup."
    exit 1
  fi
  if [[ -n "${folder_id}" && -n "${org_id}" ]]; then
    echo >&2 "I: GCP_FOLDER_ID is set; Terraform will use it instead of GCP_ORG_ID."
  fi

  if [[ -z "${project_id}" && "${has_managed_project_state}" != "true" ]]; then
    project_id="$(generate_managed_project_id)"
    echo >&2 "I: Generated managed GKE project id ${project_id}."
  fi

  if [[ "${gke_protection}" == "iap" && -z "${iap_accessor_members}" ]]; then
    local default_iap_member
    if default_iap_member="$(default_iap_accessor_member)"; then
      iap_accessor_members="${default_iap_member}"
      echo >&2 "I: Defaulting IAP accessor to active gcloud account ${default_iap_member}."
      echo >&2 "I: Set GKE_IAP_ACCESSOR_MEMBERS to override or add more accessors."
    else
      echo >&2 "E: GKE_PROTECTION=iap requires an IAP accessor member."
      echo >&2 "I: Set GKE_IAP_ACCESSOR_MEMBERS=user:you@example.com or run 'gcloud auth login --update-adc'."
      exit 1
    fi
  fi

  write_managed_tfvars \
    "${tfvars}" \
    "${billing_account_id}" \
    "${org_id}" \
    "${folder_id}" \
    "${region_value}" \
    "${project_id}" \
    "${dns_domain_value}" \
    "${writer_members}" \
    "${iap_accessor_members}" \
    "${config_connector_enabled}" \
    "${config_connector_iam_roles}"

  echo >&2 "I: Converging GKE Terraform in ${GKE_TERRAFORM_DIR}..."
  terraform -chdir="${GKE_TERRAFORM_DIR}" init -input=false
  terraform -chdir="${GKE_TERRAFORM_DIR}" apply -input=false -auto-approve

  local tf_output cluster_name dns_nameservers_value dev_registry_host_value dev_registry_value
  tf_output="$(terraform -chdir="${GKE_TERRAFORM_DIR}" output -json)"
  project_id="$(tf_output_value "${tf_output}" project_id)"
  region_value="$(tf_output_value "${tf_output}" region)"
  cluster_name="$(tf_output_value "${tf_output}" cluster_name)"
  dns_domain_value="$(tf_output_value "${tf_output}" dns_domain | sed 's/\.$//')"
  dns_nameservers_value="$(printf '%s' "${tf_output}" | yq -r '.dns_name_servers.value | join(",")')"
  dev_registry_host_value="$(tf_output_value "${tf_output}" dev_registry_host)"
  dev_registry_value="$(tf_output_value "${tf_output}" dev_registry)"

  ensure_gcloud_auth "${project_id}"

  persist_gke_selection \
    "${project_id}" \
    "${region_value}" \
    "${cluster_name}" \
    "" \
    "${dns_domain_value}" \
    "${dns_nameservers_value}" \
    "${dev_registry_host_value}" \
    "${dev_registry_value}" \
    "$(gke_gateway_namespace)"
}

ensure_gke_external() {
  local context="$1"
  local project_id region cluster_name dns_domain dns_nameservers registry_host registry gateway_namespace

  project_id="${GKE_PROJECT_ID:-$(context_project "${context}")}"
  region="${GKE_REGION:-$(context_region "${context}")}"
  cluster_name="$(context_cluster "${context}")"
  dns_domain="${GKE_DNS_DOMAIN:-${DEFAULT_GKE_DNS_DOMAIN}}"
  dns_nameservers="${GKE_DNS_NAMESERVERS:-}"
  registry_host="${DEV_REGISTRY_HOST:-}"
  registry="${DEV_REGISTRY:-}"
  gateway_namespace="$(gke_gateway_namespace)"

  if [[ -z "${registry_host}" ]]; then
    registry_host="${region}-docker.pkg.dev"
  fi
  if [[ -z "${registry}" && -n "${project_id}" ]]; then
    registry="${registry_host}/${project_id}/${DEV_REGISTRY_REPOSITORY:-${DEFAULT_DEV_REGISTRY_REPOSITORY}}"
  fi

  require_value "GKE_PROJECT_ID" "${project_id}" "Use a standard GKE context or set GKE_PROJECT_ID."
  require_value "GKE_REGION" "${region}" "Use a standard GKE context or set GKE_REGION."
  require_value "GKE_DNS_NAMESERVERS" "${dns_nameservers}" "Set Cloud DNS nameservers with 'devspace set var GKE_DNS_NAMESERVERS=...'."
  require_value "DEV_REGISTRY" "${registry}" "Set DEV_REGISTRY or provide enough registry vars to derive it."

  ensure_gcloud_auth "${project_id}"

  persist_gke_selection \
    "${project_id}" \
    "${region}" \
    "${cluster_name}" \
    "${context}" \
    "${dns_domain}" \
    "${dns_nameservers}" \
    "${registry_host}" \
    "${registry}" \
    "${gateway_namespace}"
}

destroy_cluster() {
  load_devspace_vars
  require_tool gcloud
  require_tool kubectl
  require_tool terraform
  require_tool yq

  local tf_output project_id region cluster_name dns_zone context context_provider managed_context
  tf_output="$(terraform_output_json)"
  if [[ -z "${tf_output}" ]] && ! terraform -chdir="${GKE_TERRAFORM_DIR}" state show -no-color google_project.ephemeral >/dev/null 2>&1; then
    echo >&2 "E: No managed GKE Terraform state found in ${GKE_TERRAFORM_DIR}."
    echo >&2 "I: destroy-cluster only supports starter-pack-managed GKE clusters."
    exit 1
  fi

  project_id="$(tf_output_value "${tf_output}" project_id)"
  region="$(tf_output_value "${tf_output}" region)"
  cluster_name="$(tf_output_value "${tf_output}" cluster_name)"
  dns_zone="$(tf_output_value "${tf_output}" dns_zone_name)"
  [[ -n "${project_id}" ]] || project_id="$(tf_state_value google_project.ephemeral project_id)"
  [[ -n "${project_id}" ]] || project_id="${GKE_PROJECT_ID:-}"
  [[ -n "${region}" ]] || region="$(tf_state_value google_compute_subnetwork.proxy_only region)"
  [[ -n "${region}" ]] || region="${GKE_REGION:-${DEFAULT_GKE_REGION}}"
  if [[ -z "${cluster_name}" && -n "${GKE_CLUSTER_NAME:-}" ]]; then
    cluster_name="${GKE_CLUSTER_NAME}"
  fi
  if [[ -z "${cluster_name}" && -f "${GKE_TERRAFORM_DIR}/terraform.tfvars" ]]; then
    cluster_name="$(tfvar_string cluster_name "${GKE_TERRAFORM_DIR}/terraform.tfvars")"
  fi
  [[ -n "${cluster_name}" ]] || cluster_name="${DEFAULT_GKE_CLUSTER_NAME}"
  [[ -n "${dns_zone}" ]] || dns_zone="$(tf_state_value google_dns_managed_zone.gcp_kube name)"
  [[ -n "${dns_zone}" ]] || dns_zone="${DEFAULT_GKE_DNS_ZONE_NAME}"
  require_value "project_id Terraform output" "${project_id}" "Cannot destroy without managed GKE state."
  require_value "region Terraform output" "${region}" "Cannot destroy without managed GKE state."
  require_value "dns_zone_name Terraform output" "${dns_zone}" "Cannot destroy without managed GKE state."

  context="$(current_context)"
  context_provider="$(provider_from_context "${context}")"
  if managed_context="$(terraform_context_name "${tf_output}")"; then
    :
  else
    managed_context="gke_${project_id}_${region}_${cluster_name}"
  fi
  case "${context_provider}" in
    "")
      if [[ -n "${context}" ]]; then
        echo >&2 "E: Unsupported Kubernetes context ${context}; destroy-cluster only supports starter-pack-managed GKE."
        exit 1
      fi
      ;;
    local)
      echo >&2 "E: destroy-cluster is unsupported for local clusters; use local cluster tooling instead."
      exit 1
      ;;
    gke)
      if [[ "${context}" != "${managed_context}" ]]; then
        echo >&2 "E: Current GKE context ${context} does not match managed Terraform context ${managed_context}."
        echo >&2 "I: destroy-cluster does not destroy external/pre-existing GKE clusters."
        exit 1
      fi
      ;;
  esac

  ensure_gcloud_auth "${project_id}"

  echo >&2 "I: Resetting host DNS integration if configured..."
  reset_destroy_host_dns || true

  destroy_cluster_kubernetes_cleanup "${project_id}" "${region}" "${cluster_name}" "${managed_context}"
  cleanup_gke_dns_records "${project_id}" "${dns_zone}"
  cleanup_gke_gateway_forwarding_rules "${project_id}" "${region}"
  wait_for_gke_gateway_forwarding_rules "${project_id}" "${region}"
  cleanup_gke_network_endpoint_groups "${project_id}"

  echo >&2 "I: Destroying managed GKE Terraform infrastructure..."
  terraform -chdir="${GKE_TERRAFORM_DIR}" destroy -input=false -auto-approve

  cleanup_destroyed_kube_context "${managed_context}"
  cleanup_destroyed_devspace_cache "${managed_context}" "${project_id}"
  echo >&2 "I: Managed GKE cluster destroyed."
}

reset_destroy_host_dns() {
  case "$(uname -s)" in
    Darwin)
      ./scripts/cluster-dns.sh reset-darwin cloud-dns "${DNS_SERVICE_ID:-gcp-kube}" "${GKE_DNS_DOMAIN:-gcp.kube}" "${GKE_DNS_NAMESERVERS:-}" ""
      ;;
    Linux)
      ./scripts/cluster-dns.sh reset-linux cloud-dns "${DNS_SERVICE_ID:-gcp-kube}" "${GKE_DNS_DOMAIN:-gcp.kube}" "${GKE_DNS_NAMESERVERS:-}" ""
      ;;
    *)
      echo >&2 "I: Skipping host DNS reset on unsupported OS $(uname -s)."
      ;;
  esac
}

cleanup_destroyed_kube_context() {
  local context="$1"
  local current

  current="$(current_context)"
  if [[ "${current}" == "${context}" ]]; then
    if kubectl config get-contexts -o name | grep -qx docker-desktop; then
      kubectl config use-context docker-desktop >/dev/null 2>&1 || true
    else
      kubectl config unset current-context >/dev/null 2>&1 || true
    fi
  fi

  kubectl config delete-context "${context}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "${context}" >/dev/null 2>&1 || true
  kubectl config unset "users.${context}" >/dev/null 2>&1 || true
}

cleanup_destroyed_devspace_cache() {
  local context="$1"
  local project_id="$2"
  local file

  if [[ -f .devspace/cache.yaml ]] && grep -q "${context}" .devspace/cache.yaml; then
    rm -f .devspace/cache.yaml
  fi
  while IFS= read -r file; do
    if [[ "${file}" == *"${context}"* ]] || grep -q "${project_id}" "${file}"; then
      rm -f "${file}"
    fi
  done < <(find .devspace/cache -type f 2>/dev/null || true)
}

destroy_cluster_kubernetes_cleanup() {
  local project_id="$1"
  local region="$2"
  local cluster_name="$3"
  local context="$4"

  require_tool kubectl

  echo >&2 "I: Cleaning Kubernetes Gateway and route resources when reachable..."
  if ! gcloud container clusters get-credentials "${cluster_name}" --region "${region}" --project "${project_id}" >/dev/null 2>&1; then
    echo >&2 "I: GKE credentials could not be refreshed; continuing with cloud-side cleanup."
    return
  fi
  kubectl config use-context "${context}" >/dev/null 2>&1 || true

  kubectl -n external-dns delete deployment external-dns --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete httproute -A --all --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "${GATEWAY_NAMESPACE:-${DEFAULT_GKE_GATEWAY_NAMESPACE}}" delete gateway gateway --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace httpbin observability ext-authz-token-exchange-e2e --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

gke_gateway_forwarding_rules() {
  local project_id="$1"
  local region="$2"
  gcloud compute forwarding-rules list \
    --project "${project_id}" \
    --format='value(name,region)' 2>/dev/null |
    awk -v region="${region}" '
      $1 ~ /^gkegw/ {
        rule_region = $2
        sub("^.*/regions/", "", rule_region)
        if (rule_region == region) {
          print $1
        }
      }
    '
}

cleanup_gke_gateway_forwarding_rules() {
  local project_id="$1"
  local region="$2"
  local rules rule

  rules="$(gke_gateway_forwarding_rules "${project_id}" "${region}" || true)"
  if [[ -z "${rules}" ]]; then
    return
  fi

  echo >&2 "I: Deleting stale GKE Gateway forwarding rules in ${region}: $(printf '%s' "${rules}" | tr '\n' ' ')"
  while IFS= read -r rule; do
    [[ -n "${rule}" ]] || continue
    gcloud compute forwarding-rules delete "${rule}" \
      --region="${region}" \
      --project="${project_id}" \
      --quiet >/dev/null 2>&1 || true
  done <<<"${rules}"
}

wait_for_gke_gateway_forwarding_rules() {
  local project_id="$1"
  local region="$2"
  local deadline=$((SECONDS + 600))
  local rules

  while true; do
    rules="$(gke_gateway_forwarding_rules "${project_id}" "${region}" || true)"
    if [[ -z "${rules}" ]]; then
      echo >&2 "I: No GKE Gateway forwarding rules remain in ${region}."
      return
    fi
    if (( SECONDS >= deadline )); then
      echo >&2 "E: Timed out waiting for GKE Gateway forwarding rules to be deleted:"
      printf '%s\n' "${rules}" >&2
      exit 1
    fi
    echo >&2 "I: Waiting for GKE Gateway forwarding rules to disappear: $(printf '%s' "${rules}" | tr '\n' ' ')"
    sleep 15
  done
}

cleanup_gke_dns_records() {
  local project_id="$1"
  local zone="$2"
  local name type

  echo >&2 "I: Deleting non-default Cloud DNS records in zone ${zone}..."
  while IFS=, read -r name type; do
    [[ -n "${name}" && -n "${type}" ]] || continue
    case "${type}" in
      NS | SOA)
        continue
        ;;
    esac
    gcloud dns record-sets delete "${name}" \
      --type="${type}" \
      --zone="${zone}" \
      --project="${project_id}" \
      --quiet >/dev/null 2>&1 || true
  done < <(gcloud dns record-sets list \
    --project "${project_id}" \
    --zone "${zone}" \
    --format='csv[no-heading](name,type)' 2>/dev/null || true)
}

cleanup_gke_network_endpoint_groups() {
  local project_id="$1"
  local deadline groups name zone region zone_name region_name

  deadline=$((SECONDS + 600))
  while true; do
    groups="$(gcloud compute network-endpoint-groups list \
      --project "${project_id}" \
      --format='csv[no-heading](name,zone,region)' 2>/dev/null |
      awk -F, '$1 ~ /^k8s1-/ { print }' || true)"

    if [[ -z "${groups}" ]]; then
      echo >&2 "I: No GKE-created network endpoint groups remain."
      return
    fi
    if (( SECONDS >= deadline )); then
      echo >&2 "E: Timed out waiting for GKE-created network endpoint groups to be deleted:"
      printf '%s\n' "${groups}" >&2
      exit 1
    fi

    echo >&2 "I: Deleting GKE-created network endpoint groups: $(printf '%s' "${groups}" | cut -d, -f1 | tr '\n' ' ')"
    while IFS=, read -r name zone region; do
      [[ -n "${name}" ]] || continue
      zone_name="${zone##*/}"
      region_name="${region##*/}"
      if [[ -n "${zone_name}" ]]; then
        gcloud compute network-endpoint-groups delete "${name}" \
          --zone="${zone_name}" \
          --project="${project_id}" \
          --quiet >/dev/null 2>&1 || true
      elif [[ -n "${region_name}" ]]; then
        gcloud compute network-endpoint-groups delete "${name}" \
          --region="${region_name}" \
          --project="${project_id}" \
          --quiet >/dev/null 2>&1 || true
      fi
    done <<<"${groups}"
    sleep 15
  done
}

persist_gke_selection() {
  local project_id="$1"
  local region="$2"
  local cluster_name="$3"
  local context="$4"
  local dns_domain="$5"
  local dns_nameservers="$6"
  local registry_host="$7"
  local registry="$8"
  local gateway_namespace="$9"
  local previous_namespace
  previous_namespace="$(current_namespace)"

  if [[ -z "${context}" ]]; then
    require_value "GKE_PROJECT_ID" "${project_id}" "Managed GKE Terraform output is missing project_id."
    require_value "GKE_REGION" "${region}" "Managed GKE Terraform output is missing region."
    require_value "GKE_CLUSTER_NAME" "${cluster_name}" "Managed GKE Terraform output is missing cluster_name."
    gcloud container clusters get-credentials "${cluster_name}" --region "${region}" --project "${project_id}"
    context="$(current_context)"
  else
    select_context_preserving_namespace "${context}" "${previous_namespace}"
  fi
  select_context_preserving_namespace "${context}" "${previous_namespace}"

  local derived_provider
  derived_provider="$(provider_from_context "${context}")"
  if [[ "${derived_provider}" != "gke" ]]; then
    echo >&2 "E: Selected context ${context} is not a GKE context."
    exit 1
  fi
  kubectl cluster-info >/dev/null

  local config_connector_enabled config_connector_mode config_connector_project_id config_connector_service_account
  config_connector_enabled="${CONFIG_CONNECTOR_ENABLED:-false}"
  if [[ "${config_connector_enabled}" == "true" ]]; then
    config_connector_service_account="$(managed_config_connector_service_account "${context}")"
  else
    config_connector_service_account=""
  fi
  if [[ "${config_connector_enabled}" == "true" && -n "${config_connector_service_account}" ]]; then
    config_connector_enabled="true"
    config_connector_mode="cluster"
    config_connector_project_id="${project_id}"
  else
    config_connector_enabled="false"
    config_connector_mode=""
    config_connector_project_id=""
    config_connector_service_account=""
  fi

  GKE_PROJECT_ID="${project_id}"
  GKE_REGION="${region}"
  GKE_DNS_DOMAIN="${dns_domain%.}"
  DNS_DOMAIN="${dns_domain%.}"
  GKE_DNS_NAMESERVERS="${dns_nameservers}"
  GKE_SELECTED_CONTEXT="${context}"
  DEV_REGISTRY_HOST="${registry_host}"
  DEV_REGISTRY="${registry}"
  DEV_REGISTRY_IMAGE_PREFIX="${registry}"
  CONFIG_CONNECTOR_ENABLED="${config_connector_enabled}"
  CONFIG_CONNECTOR_MODE="${config_connector_mode}"
  CONFIG_CONNECTOR_PROJECT_ID="${config_connector_project_id}"
  CONFIG_CONNECTOR_SERVICE_ACCOUNT="${config_connector_service_account}"
  GATEWAY_NAMESPACE="${gateway_namespace}"
  GATEWAY_PROVIDER="gke-gateway"
  DNS_MODE="cloud-dns"
  DNS_SERVICE_ID="gcp-kube"

  gcloud auth configure-docker "${registry_host}"

  publish_cluster_env
  echo >&2 "I: GKE cluster selected: ${context}"
  print_gke_registry_info "${registry_host}" "${registry}"
}

print_gke_registry_info() {
  local registry_host="$1"
  local registry="$2"

  echo "export DEV_REGISTRY_HOST=${registry_host}"
  echo "export DEV_REGISTRY=${registry}"
  echo "export DEV_REGISTRY_IMAGE_PREFIX=${registry}"
  echo "gcloud auth configure-docker ${registry_host}"
}

validate_gke_selection() {
  local context="$1"
  local selected_context="${GKE_SELECTED_CONTEXT:-}"
  local contract_json=""

  contract_json="$(kubectl -n "${CLUSTER_ENV_NAMESPACE}" get configmap "${CLUSTER_ENV_CONFIGMAP}" -o json 2>/dev/null || true)"
  if [[ -n "${contract_json}" && "$(contract_value "${contract_json}" STARTER_PACK_ENV_VERSION)" == "v1" ]]; then
    [[ -n "${selected_context}" ]] || selected_context="$(contract_value "${contract_json}" GKE_SELECTED_CONTEXT)"
  fi

  if [[ -z "${selected_context}" ]]; then
    echo >&2 "E: Current context ${context} is GKE, but no GKE selection has been persisted."
    echo >&2 "I: Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster'."
    exit 1
  fi
  if [[ "${selected_context}" != "${context}" ]]; then
    echo >&2 "E: Cached GKE vars were selected for ${selected_context}, but current context is ${context}."
    echo >&2 "I: Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster' to refresh GKE selection."
    exit 1
  fi

  local gke_project_id gke_region gke_dns_nameservers dev_registry dev_registry_image_prefix
  gke_project_id="${GKE_PROJECT_ID:-}"
  gke_region="${GKE_REGION:-}"
  gke_dns_nameservers="${GKE_DNS_NAMESERVERS:-}"
  dev_registry="${DEV_REGISTRY:-}"
  dev_registry_image_prefix="${DEV_REGISTRY_IMAGE_PREFIX:-}"
  if [[ -n "${contract_json}" && "$(contract_value "${contract_json}" STARTER_PACK_ENV_VERSION)" == "v1" ]]; then
    [[ -n "${gke_project_id}" ]] || gke_project_id="$(contract_value "${contract_json}" GKE_PROJECT_ID)"
    [[ -n "${gke_region}" ]] || gke_region="$(contract_value "${contract_json}" GKE_REGION)"
    [[ -n "${gke_dns_nameservers}" ]] || gke_dns_nameservers="$(contract_value "${contract_json}" GKE_DNS_NAMESERVERS)"
    [[ -n "${dev_registry}" ]] || dev_registry="$(contract_value "${contract_json}" DEV_REGISTRY)"
    [[ -n "${dev_registry_image_prefix}" ]] || dev_registry_image_prefix="$(contract_value "${contract_json}" DEV_REGISTRY_IMAGE_PREFIX)"
  fi

  require_value "GKE_PROJECT_ID" "${gke_project_id}" "Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster'."
  require_value "GKE_REGION" "${gke_region}" "Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster'."
  require_value "GKE_DNS_NAMESERVERS" "${gke_dns_nameservers}" "Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster'."
  require_value "DEV_REGISTRY" "${dev_registry}" "Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster'."
  require_value "DEV_REGISTRY_IMAGE_PREFIX" "${dev_registry_image_prefix}" "Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster'."
}

gke_traffic_extension_forward_attributes_supported() {
  local field_type
  field_type="$(kubectl get crd gcptrafficextensions.networking.gke.io \
    -o jsonpath='{.spec.versions[?(@.name=="v1")].schema.openAPIV3Schema.properties.spec.properties.extensionChains.items.properties.extensions.items.properties.forwardAttributes.type}' 2>/dev/null || true)"
  [[ -n "${field_type}" ]]
}

check_gke_service_extensions() {
  load_devspace_vars
  require_tool kubectl

  local context provider component_version
  context="$(current_context)"
  provider="$(require_supported_context)"
  validate_provider_override "${provider}"
  if [[ "${provider}" != "gke" ]]; then
    echo >&2 "I: GKE Service Extensions prerequisites are not applicable to provider ${provider}."
    return
  fi
  validate_gke_selection "${context}"

  if ! kubectl get crd gcptrafficextensions.networking.gke.io >/dev/null 2>&1; then
    echo >&2 "E: GKE Service Extensions CRD gcptrafficextensions.networking.gke.io is not installed."
    echo >&2 "I: Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster' and 'devspace deploy' from starter-pack."
    exit 1
  fi

  component_version="$(kubectl get crd gcptrafficextensions.networking.gke.io \
    -o jsonpath='{.metadata.annotations.components\.gke\.io/component-version}' 2>/dev/null || true)"
  if ! gke_traffic_extension_forward_attributes_supported; then
    echo >&2 "E: Installed GCPTrafficExtension CRD does not support spec.extensionChains[].extensions[].forwardAttributes."
    echo >&2 "I: Installed GKE Gateway CRD component version: ${component_version:-unknown}."
    echo >&2 "I: Upgrade the GKE control plane to a version whose managed Gateway API CRD bundle includes forwardAttributes, then retry."
    exit 1
  fi

  echo >&2 "I: GCPTrafficExtension forwardAttributes is available (component ${component_version:-unknown})."
}

validate_provider() {
  load_devspace_vars
  local context derived_provider
  context="$(current_context)"
  derived_provider="$(require_supported_context)"
  validate_provider_override "${derived_provider}"
  if [[ "${derived_provider}" == "gke" ]]; then
    validate_gke_selection "${context}"
  fi
  echo >&2 "I: Current Kubernetes context provider is ${derived_provider}."
}

publish_cluster_env() {
  load_devspace_vars
  require_tool kubectl

  local context provider
  context="$(current_context)"
  provider="$(require_supported_context)"
  validate_provider_override "${provider}"
  if [[ "${provider}" == "gke" ]]; then
    validate_gke_selection "${context}"
  fi

  local deployment_domain dns_domain dns_mode dns_service_id gateway_namespace gateway_provider
  local gke_dns_domain gke_dns_nameservers gke_project_id gke_region gke_selected_context gke_protection dev_registry_host dev_registry dev_registry_image_prefix
  local gke_service_extensions_forward_attributes
  local config_connector_enabled config_connector_mode config_connector_project_id config_connector_service_account
  local existing_contract_json=""

  existing_contract_json="$(kubectl -n "${CLUSTER_ENV_NAMESPACE}" get configmap "${CLUSTER_ENV_CONFIGMAP}" -o json 2>/dev/null || true)"

  case "${provider}" in
    local)
      dns_domain="${DNS_DOMAIN:-int.kube}"
      deployment_domain="${dns_domain}"
      dns_mode="${DNS_MODE:-local}"
      dns_service_id="${DNS_SERVICE_ID:-kube}"
      gateway_namespace="${GATEWAY_NAMESPACE:-istio-ingress}"
      gateway_provider="${GATEWAY_PROVIDER:-local-istio}"
      gke_dns_domain=""
      gke_dns_nameservers=""
      gke_project_id=""
      gke_region=""
      gke_selected_context=""
      gke_protection=""
      gke_service_extensions_forward_attributes=""
      dev_registry_host=""
      dev_registry=""
      dev_registry_image_prefix="${DEV_REGISTRY_IMAGE_PREFIX:-}"
      config_connector_enabled="false"
      config_connector_mode=""
      config_connector_project_id=""
      config_connector_service_account=""
      ;;
    gke)
      gke_dns_domain="${GKE_DNS_DOMAIN:-${DEFAULT_GKE_DNS_DOMAIN}}"
      gke_dns_nameservers="${GKE_DNS_NAMESERVERS:-}"
      deployment_domain="${gke_dns_domain%.}"
      dns_domain="${deployment_domain}"
      dns_mode="${DNS_MODE:-cloud-dns}"
      dns_service_id="${DNS_SERVICE_ID:-gcp-kube}"
      gateway_namespace="$(gke_gateway_namespace)"
      gateway_provider="${GATEWAY_PROVIDER:-gke-gateway}"
      gke_project_id="${GKE_PROJECT_ID:-}"
      gke_region="${GKE_REGION:-${DEFAULT_GKE_REGION}}"
      gke_selected_context="${GKE_SELECTED_CONTEXT:-${context}}"
      gke_protection="${GKE_PROTECTION:-${DEFAULT_GKE_PROTECTION}}"
      if [[ -n "${existing_contract_json}" && "$(contract_value "${existing_contract_json}" STARTER_PACK_ENV_VERSION)" == "v1" ]]; then
        [[ -n "${gke_project_id}" ]] || gke_project_id="$(contract_value "${existing_contract_json}" GKE_PROJECT_ID)"
        [[ -n "${gke_region}" ]] || gke_region="$(contract_value "${existing_contract_json}" GKE_REGION)"
        [[ -n "${gke_selected_context}" ]] || gke_selected_context="$(contract_value "${existing_contract_json}" GKE_SELECTED_CONTEXT)"
        [[ -n "${gke_dns_domain}" ]] || gke_dns_domain="$(contract_value "${existing_contract_json}" GKE_DNS_DOMAIN)"
        [[ -n "${gke_dns_nameservers}" ]] || gke_dns_nameservers="$(contract_value "${existing_contract_json}" GKE_DNS_NAMESERVERS)"
        [[ -n "${gke_protection}" ]] || gke_protection="$(contract_value "${existing_contract_json}" GKE_PROTECTION)"
      fi
      if gke_traffic_extension_forward_attributes_supported; then
        gke_service_extensions_forward_attributes="true"
      else
        gke_service_extensions_forward_attributes="false"
      fi
      dev_registry_host="${DEV_REGISTRY_HOST:-}"
      dev_registry="${DEV_REGISTRY:-}"
      dev_registry_image_prefix="${DEV_REGISTRY_IMAGE_PREFIX:-${dev_registry}}"
      if [[ -n "${existing_contract_json}" && "$(contract_value "${existing_contract_json}" STARTER_PACK_ENV_VERSION)" == "v1" ]]; then
        [[ -n "${dev_registry_host}" ]] || dev_registry_host="$(contract_value "${existing_contract_json}" DEV_REGISTRY_HOST)"
        [[ -n "${dev_registry}" ]] || dev_registry="$(contract_value "${existing_contract_json}" DEV_REGISTRY)"
        [[ -n "${dev_registry_image_prefix}" ]] || dev_registry_image_prefix="$(contract_value "${existing_contract_json}" DEV_REGISTRY_IMAGE_PREFIX)"
      fi
      config_connector_enabled="${CONFIG_CONNECTOR_ENABLED:-false}"
      if [[ "${config_connector_enabled}" == "true" ]]; then
        config_connector_service_account="$(managed_config_connector_service_account "${context}")"
      else
        config_connector_service_account=""
      fi
      if [[ "${config_connector_enabled}" == "true" && -n "${config_connector_service_account}" ]]; then
        config_connector_enabled="true"
        config_connector_mode="cluster"
        config_connector_project_id="${gke_project_id}"
      else
        config_connector_enabled="false"
        config_connector_mode=""
        config_connector_project_id=""
        config_connector_service_account=""
      fi
      require_value "GKE_PROJECT_ID" "${gke_project_id}" "Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster'."
      require_value "GKE_REGION" "${gke_region}" "Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster'."
      require_value "DEV_REGISTRY_IMAGE_PREFIX" "${dev_registry_image_prefix}" "Run 'devspace --var CLUSTER_PROVIDER=gke run ensure-cluster'."
      ;;
    *)
      echo >&2 "E: Unsupported cluster provider ${provider}."
      exit 1
      ;;
  esac

  kubectl create namespace "${CLUSTER_ENV_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${CLUSTER_ENV_NAMESPACE}" create configmap "${CLUSTER_ENV_CONFIGMAP}" \
    --from-literal=STARTER_PACK_ENV_VERSION=v1 \
    --from-literal=CLUSTER_PROVIDER="${provider}" \
    --from-literal=DEPLOYMENT_DOMAIN="${deployment_domain}" \
    --from-literal=DNS_DOMAIN="${dns_domain}" \
    --from-literal=DNS_MODE="${dns_mode}" \
    --from-literal=DNS_SERVICE_ID="${dns_service_id}" \
    --from-literal=GATEWAY_NAMESPACE="${gateway_namespace}" \
    --from-literal=GATEWAY_PROVIDER="${gateway_provider}" \
    --from-literal=DEV_REGISTRY_IMAGE_PREFIX="${dev_registry_image_prefix}" \
    --from-literal=GKE_DNS_DOMAIN="${gke_dns_domain}" \
    --from-literal=GKE_DNS_NAMESERVERS="${gke_dns_nameservers}" \
    --from-literal=GKE_PROJECT_ID="${gke_project_id}" \
    --from-literal=GKE_REGION="${gke_region}" \
    --from-literal=GKE_SELECTED_CONTEXT="${gke_selected_context}" \
    --from-literal=GKE_PROTECTION="${gke_protection}" \
    --from-literal=GKE_SERVICE_EXTENSIONS_FORWARD_ATTRIBUTES="${gke_service_extensions_forward_attributes}" \
    --from-literal=DEV_REGISTRY_HOST="${dev_registry_host}" \
    --from-literal=DEV_REGISTRY="${dev_registry}" \
    --from-literal=CONFIG_CONNECTOR_ENABLED="${config_connector_enabled}" \
    --from-literal=CONFIG_CONNECTOR_MODE="${config_connector_mode}" \
    --from-literal=CONFIG_CONNECTOR_PROJECT_ID="${config_connector_project_id}" \
    --from-literal=CONFIG_CONNECTOR_SERVICE_ACCOUNT="${config_connector_service_account}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${CLUSTER_ENV_NAMESPACE}" label configmap "${CLUSTER_ENV_CONFIGMAP}" \
    devspace.magneticflux.net/contract=starter-pack-env --overwrite >/dev/null

  echo >&2 "I: Published cluster environment contract ${CLUSTER_ENV_NAMESPACE}/${CLUSTER_ENV_CONFIGMAP}."
}

managed_config_connector_service_account() {
  local context="$1"
  local tf_output
  tf_output="$(terraform_output_json)"
  if [[ -z "${tf_output}" ]]; then
    return
  fi
  if ! terraform_outputs_match_context "${tf_output}" "${context}"; then
    return
  fi
  tf_output_value "${tf_output}" config_connector_service_account_email
}

contract_value() {
  local json="$1"
  local key="$2"
  printf '%s' "${json}" | yq -r ".data[\"${key}\"] // \"\""
}

require_contract_value() {
  local json="$1"
  local key="$2"
  local value
  value="$(contract_value "${json}" "${key}")"
  if [[ -z "${value}" ]]; then
    echo >&2 "E: Cluster environment contract is missing ${key}."
    echo >&2 "I: Run 'devspace run ensure-cluster' or deploy starter-pack infrastructure."
    exit 1
  fi
}

print_cluster_env() {
  require_tool kubectl
  require_tool yq

  local json provider
  if ! json="$(kubectl -n "${CLUSTER_ENV_NAMESPACE}" get configmap "${CLUSTER_ENV_CONFIGMAP}" -o json 2>/dev/null)"; then
    echo >&2 "E: Cluster environment contract ${CLUSTER_ENV_NAMESPACE}/${CLUSTER_ENV_CONFIGMAP} was not found."
    echo >&2 "I: Run 'devspace run ensure-cluster' or deploy starter-pack infrastructure."
    exit 1
  fi

  require_contract_value "${json}" STARTER_PACK_ENV_VERSION
  require_contract_value "${json}" CLUSTER_PROVIDER
  require_contract_value "${json}" DEPLOYMENT_DOMAIN
  require_contract_value "${json}" DNS_DOMAIN
  require_contract_value "${json}" GATEWAY_NAMESPACE
  require_contract_value "${json}" GATEWAY_PROVIDER

  provider="$(contract_value "${json}" CLUSTER_PROVIDER)"
  if [[ "${provider}" == "gke" ]]; then
    require_contract_value "${json}" GKE_PROJECT_ID
    require_contract_value "${json}" GKE_REGION
    require_contract_value "${json}" GKE_PROTECTION
    require_contract_value "${json}" GKE_SERVICE_EXTENSIONS_FORWARD_ATTRIBUTES
    require_contract_value "${json}" DEV_REGISTRY_IMAGE_PREFIX
    if [[ "$(contract_value "${json}" CONFIG_CONNECTOR_ENABLED)" == "true" ]]; then
      require_contract_value "${json}" CONFIG_CONNECTOR_MODE
      require_contract_value "${json}" CONFIG_CONNECTOR_PROJECT_ID
      require_contract_value "${json}" CONFIG_CONNECTOR_SERVICE_ACCOUNT
    fi
  fi

  printf '%s' "${json}" | yq -r '.data | to_entries | sort_by(.key) | .[] | .key + "=" + .value'
}

test_install() {
  load_devspace_vars
  local derived_provider
  derived_provider="$(require_supported_context)"
  validate_provider_override "${derived_provider}"
  CLUSTER_PROVIDER="${derived_provider}" CGO_ENABLED=1 go test -count=1 -v -timeout 5m ./tests/install
}

command_name="${1:-}"
if [[ -z "${command_name}" ]]; then
  echo >&2 "E: Missing command name"
  exit 1
fi
shift

case "${command_name}" in
  ensure | destroy-cluster | validate-provider | check-gke-service-extensions | publish-cluster-env | print-cluster-env | test-install)
    ;;
  *)
    echo >&2 "E: Unknown command ${command_name}"
    exit 1
    ;;
esac

function_name="${command_name//-/_}"
"${function_name}" "$@"
