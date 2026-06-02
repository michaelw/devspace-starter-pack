#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
if [[ -z "${command_name}" ]]; then
  echo >&2 "E: Missing DNS command"
  exit 1
fi
shift

DNS_MODE_VALUE="${1:-local}"
DNS_SERVICE_ID_VALUE="${2:-kube}"
GKE_DNS_DOMAIN_VALUE="${3:-gcp.kube}"
GKE_DNS_NAMESERVERS_VALUE="${4:-}"
DOCKER_CIDR_PREFIX_VALUE="${5:-172.18.255}"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo >&2 "E: Required command not found: $1"
    exit 1
  fi
}

cloud_dns_domain() {
  printf '%s\n' "${GKE_DNS_DOMAIN_VALUE%.}"
}

cloud_dns_nameserver_ips() {
  local resolver="$1"
  local ns
  if [[ -z "${GKE_DNS_NAMESERVERS_VALUE}" ]]; then
    echo >&2 "E: GKE_DNS_NAMESERVERS is required when DNS_MODE=cloud-dns"
    exit 1
  fi

  printf '%s' "${GKE_DNS_NAMESERVERS_VALUE}" | tr ',' '\n' | while IFS= read -r ns; do
    ns="${ns#"${ns%%[![:space:]]*}"}"
    ns="${ns%"${ns##*[![:space:]]}"}"
    [[ -n "${ns}" ]] || continue
    case "${resolver}" in
      darwin)
        dig +short A "${ns%.}."
        ;;
      linux)
        getent ahostsv4 "${ns%.}." | awk '{print $1}'
        ;;
      *)
        echo >&2 "E: Unknown DNS resolver ${resolver}"
        exit 1
        ;;
    esac
  done | awk 'NF && !seen[$0]++'
}

read_cloud_dns_ips() {
  local resolver="$1"
  DNS_IPS=()
  local ip
  while IFS= read -r ip; do
    [[ -n "${ip}" ]] || continue
    DNS_IPS+=("${ip}")
  done < <(cloud_dns_nameserver_ips "${resolver}")

  if [[ "${#DNS_IPS[@]}" -eq 0 ]]; then
    echo >&2 "E: Could not resolve Cloud DNS nameserver addresses from ${GKE_DNS_NAMESERVERS_VALUE}"
    exit 1
  fi
}

linux_route_link_for_ip() {
  local ip="$1"
  ip route get "${ip}" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

linux_link_for_domain() {
  local domain="$1"
  resolvectl status | awk -v domain="~${domain}" '
    /^Link / {link=$2}
    index($0, domain) {print link; exit}
  '
}

update_darwin() {
  require_tool sudo
  require_tool scutil
  echo >&2 "I: Updating DNS settings..."

  if [[ "${DNS_MODE_VALUE}" == "cloud-dns" ]]; then
    require_tool dig
    read_cloud_dns_ips darwin
    sudo scutil <<EOF
open
d.init
d.add ServerAddresses * ${DNS_IPS[*]}
d.add SupplementalMatchDomains * $(cloud_dns_domain)
set State:/Network/Service/${DNS_SERVICE_ID_VALUE}/DNS
quit
EOF
    return
  fi

  sudo scutil <<EOF
open
d.init
d.add ServerAddresses * ${DOCKER_CIDR_PREFIX_VALUE}.254
d.add SupplementalMatchDomains * kube
set State:/Network/Service/${DNS_SERVICE_ID_VALUE}/DNS
quit
EOF
}

update_linux() {
  require_tool sudo
  require_tool resolvectl
  require_tool ip

  local link
  if [[ "${DNS_MODE_VALUE}" == "cloud-dns" ]]; then
    require_tool getent
    read_cloud_dns_ips linux
    link="$(linux_route_link_for_ip "${DNS_IPS[0]}")"
    if [[ -z "${link}" ]]; then
      echo >&2 "E: Could not determine Linux route interface for Cloud DNS"
      exit 1
    fi
    sudo resolvectl dns "${link}" "${DNS_IPS[@]}"
    sudo resolvectl domain "${link}" "~$(cloud_dns_domain)"
    sudo resolvectl flush-caches
    return
  fi

  local dns_ip="${DOCKER_CIDR_PREFIX_VALUE}.254"
  echo >&2 "I: Updating systemd-resolved DNS settings..."
  link="$(linux_route_link_for_ip "${dns_ip}")"
  if [[ -z "${link}" ]]; then
    echo >&2 "E: Could not determine Linux route interface for ${dns_ip}"
    exit 1
  fi
  sudo resolvectl dns "${link}" "${dns_ip}"
  sudo resolvectl domain "${link}" "~kube"
  sudo resolvectl flush-caches
}

reset_darwin() {
  require_tool sudo
  require_tool scutil
  echo >&2 "I: Resetting DNS..."
  sudo scutil <<EOF
open
remove State:/Network/Service/${DNS_SERVICE_ID_VALUE}/DNS
quit
EOF
}

reset_linux() {
  require_tool sudo
  require_tool resolvectl

  local link
  if [[ "${DNS_MODE_VALUE}" == "cloud-dns" ]]; then
    link="$(linux_link_for_domain "$(cloud_dns_domain)")"
    if [[ -z "${link}" ]]; then
      echo >&2 "I: No systemd-resolved link found for ~$(cloud_dns_domain)"
      return
    fi
    sudo resolvectl revert "${link}"
    sudo resolvectl flush-caches
    return
  fi

  require_tool ip
  local dns_ip="${DOCKER_CIDR_PREFIX_VALUE}.254"
  echo >&2 "I: Resetting systemd-resolved DNS settings..."
  link="$(linux_route_link_for_ip "${dns_ip}")"
  if [[ -z "${link}" ]]; then
    echo >&2 "E: Could not determine Linux route interface for ${dns_ip}"
    exit 1
  fi
  sudo resolvectl revert "${link}"
  sudo resolvectl flush-caches
}

function_name="${command_name//-/_}"
if [[ ! "${function_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || ! declare -F "${function_name}" >/dev/null; then
  echo >&2 "E: Unknown DNS command ${command_name}"
  exit 1
fi

"${function_name}"
