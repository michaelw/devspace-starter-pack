#!/bin/sh
set -eu

if [ -n "${DOCKER_CIDR_PREFIX:-}" ]; then
  printf '%s\n' "${DOCKER_CIDR_PREFIX}"
  exit 0
fi

network_subnet() {
  "${docker}" network inspect "$1" --format '{{range .IPAM.Config}}{{if .Subnet}}{{.Subnet}}{{println}}{{end}}{{end}}' 2>/dev/null \
    | sed -n '/^[0-9][0-9.]*\/[0-9][0-9]*$/ { p; q; }'
}

subnet_to_prefix() {
  printf '%s\n' "$1" | awk -F '[./]' '
    NF == 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 == "0" {
      if ($5 == 16) {
        print $1 "." $2 ".255"
        found = 1
      } else if ($5 == 24) {
        print $1 "." $2 "." $3
        found = 1
      }
    }
    END {
      if (!found) {
        exit 1
      }
    }
  '
}

candidate_networks="${DOCKER_NETWORK_NAME:-}"
if [ -z "${candidate_networks}" ]; then
  case "${DEVSPACE_CONTEXT:-}" in
    kind|kind-*) candidate_networks="kind bridge" ;;
    *) candidate_networks="kind bridge" ;;
  esac
fi

docker="$(command -v docker || true)"
if [ -z "${docker}" ]; then
  for candidate in /opt/homebrew/bin/docker /usr/local/bin/docker /Applications/Docker.app/Contents/Resources/bin/docker; do
    if [ -x "${candidate}" ]; then
      docker="${candidate}"
      break
    fi
  done
fi

if [ -z "${docker}" ]; then
  cat >&2 <<'EOF'
E: Could not find the Docker CLI.
   Set DOCKER_CIDR_PREFIX explicitly, for example:
   DOCKER_CIDR_PREFIX=172.18.255 devspace deploy
EOF
  exit 1
fi

for network in ${candidate_networks}; do
  subnet="$(network_subnet "${network}")"
  if [ -n "${subnet}" ] && prefix="$(subnet_to_prefix "${subnet}")"; then
    printf '%s\n' "${prefix}"
    exit 0
  fi
done

cat >&2 <<'EOF'
E: Could not discover a Docker network CIDR prefix.
   Set DOCKER_CIDR_PREFIX explicitly, for example:
   DOCKER_CIDR_PREFIX=172.18.255 devspace deploy
EOF
exit 1
