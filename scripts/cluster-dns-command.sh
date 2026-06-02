#!/usr/bin/env bash
set -euo pipefail

action="${1:?usage: cluster-dns-command.sh ACTION DOCKER_CIDR_PREFIX}"
docker_cidr_prefix="${2:-}"

contract_namespace="devspace-system"
contract_name="devspace-starter-pack-env"

contract_value() {
  local key="$1"
  kubectl -n "${contract_namespace}" get configmap "${contract_name}" \
    -o "jsonpath={.data.${key}}" 2>/dev/null || true
}

dns_mode="${DNS_MODE:-local}"
dns_service_id="${DNS_SERVICE_ID:-kube}"
gke_dns_domain="${GKE_DNS_DOMAIN:-gcp.kube}"
gke_dns_nameservers="${GKE_DNS_NAMESERVERS:-}"

if [[ "$(contract_value STARTER_PACK_ENV_VERSION)" == "v1" ]]; then
  dns_mode="$(contract_value DNS_MODE)"
  dns_service_id="$(contract_value DNS_SERVICE_ID)"
  gke_dns_domain="$(contract_value GKE_DNS_DOMAIN)"
  gke_dns_nameservers="$(contract_value GKE_DNS_NAMESERVERS)"
fi

exec ./scripts/cluster-dns.sh \
  "${action}" \
  "${dns_mode:-local}" \
  "${dns_service_id:-kube}" \
  "${gke_dns_domain:-gcp.kube}" \
  "${gke_dns_nameservers}" \
  "${docker_cidr_prefix}"
