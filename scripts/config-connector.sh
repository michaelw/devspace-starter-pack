#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
if [[ -z "${command_name}" ]]; then
  echo >&2 "E: Missing command name"
  exit 1
fi
shift

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo >&2 "E: Required command not found: $1"
    exit 1
  fi
}

install_operator() {
  if [[ "${CONFIG_CONNECTOR_ENABLED:-false}" != "true" ]]; then
    echo >&2 "I: Skipping Config Connector operator because CONFIG_CONNECTOR_ENABLED=${CONFIG_CONNECTOR_ENABLED:-false}."
    return
  fi

  require_tool kubectl
  require_tool tar

  if kubectl get crd configconnectors.core.cnrm.cloud.google.com >/dev/null 2>&1; then
    echo >&2 "I: Config Connector operator CRD is already installed."
    return
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf '${tmpdir}'" EXIT

  echo >&2 "I: Downloading Config Connector operator bundle..."
  download_operator_bundle "${tmpdir}/release-bundle.tar.gz"
  tar -xzf "${tmpdir}/release-bundle.tar.gz" -C "${tmpdir}"

  echo >&2 "I: Applying Config Connector Autopilot operator..."
  kubectl apply -f "${tmpdir}/operator-system/autopilot-configconnector-operator.yaml"
  kubectl wait --for=condition=Established crd/configconnectors.core.cnrm.cloud.google.com --timeout=300s
}

download_operator_bundle() {
  local destination="$1"
  local source="gs://configconnector-operator/latest/release-bundle.tar.gz"

  if command -v gsutil >/dev/null 2>&1; then
    if gsutil cp "${source}" "${destination}"; then
      return
    fi
    echo >&2 "I: gsutil download failed; falling back to gcloud storage cp."
  fi

  require_tool gcloud
  gcloud storage cp "${source}" "${destination}"
}

case "${command_name}" in
  install-operator)
    install_operator
    ;;
  *)
    echo >&2 "E: Unknown command ${command_name}"
    exit 1
    ;;
esac
