#!/usr/bin/env bash
set -euo pipefail

LOCAL_CONTEXT_REGEX='^(kind(-.*)?|docker-desktop|minikube|rancher-desktop|microk8s)$'

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo >&2 "E: Required command not found: $1"
    exit 1
  fi
}

require_gke_gcloud_auth_plugin() {
  if command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
    return
  fi

  local sdk_root
  sdk_root="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null || true)"
  if [[ -n "${sdk_root}" && -x "${sdk_root}/bin/gke-gcloud-auth-plugin" ]]; then
    return
  fi

  echo >&2 "E: Required command not found: gke-gcloud-auth-plugin"
  echo >&2 "I: Install the gke-gcloud-auth-plugin component or add the Google Cloud SDK bin directory to PATH."
  exit 1
}

current_context() {
  kubectl config current-context 2>/dev/null || true
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

require_host_integration_tools() {
  case "$(uname -s)" in
    Darwin)
      require_tool brew
      require_tool scutil
      require_tool security
      require_tool openssl
      require_tool base64
      ;;
    Linux)
      require_tool resolvectl
      require_tool ip
      require_tool openssl
      require_tool base64
      ;;
    *)
      echo >&2 "E: HOST_INTEGRATION=true is only supported on macOS and Linux."
      exit 1
      ;;
  esac
}

require_tool kubectl
require_tool helm
require_tool yq

provider="$(require_supported_context)"
host_integration="${HOST_INTEGRATION:-true}"
dns_mode="${DNS_MODE:-local}"
docker_cidr_prefix="${DOCKER_CIDR_PREFIX:-}"

case "${provider}" in
  local)
    if [[ -z "${docker_cidr_prefix}" ]]; then
      require_tool docker
    fi
    if [[ "${host_integration}" == "true" ]]; then
      require_host_integration_tools
    fi
    ;;
  gke)
    require_tool gcloud
    require_tool terraform
    require_gke_gcloud_auth_plugin
    if [[ "${host_integration}" == "true" && "${dns_mode}" == "cloud-dns" ]]; then
      require_tool dig
    fi
    ;;
esac

echo >&2 "I: Tool preflight passed for ${provider} context."
