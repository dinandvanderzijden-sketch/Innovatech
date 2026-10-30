#!/usr/bin/env bash
# Gedeelde helpers voor de demo-scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

tf() {
  terraform -chdir="$ROOT/infra" "$@"
}

tf_output() {
  tf output -raw "$1"
}

require() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Fout: '$cmd' is niet gevonden. Installeer het en probeer opnieuw." >&2
      exit 1
    fi
  done
}

info() {
  printf '\n\033[1;36m%s\033[0m\n' "$*"
}

warn() {
  printf '\n\033[1;33m%s\033[0m\n' "$*"
}

aws_region() {
  tf_output aws_region
}
