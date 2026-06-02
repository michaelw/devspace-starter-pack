#!/usr/bin/env bash
set -euo pipefail

key="${1:?usage: cluster-env-var.sh KEY DEFAULT}"
default="${2:-}"

value="$(kubectl -n devspace-system get configmap devspace-starter-pack-env -o "jsonpath={.data.${key}}" 2>/dev/null || true)"
if [[ -n "${value}" ]]; then
  printf '%s' "${value}"
else
  printf '%s' "${default}"
fi
