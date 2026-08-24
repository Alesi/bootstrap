#!/bin/bash

# Install or update the opencode CLI on Kali Linux.
#
# Fresh installs default to the official standalone build (no root needed).
# The npm channel is available via --method npm and requires Node.js, which
# this script will not install on its own; it prints the apt command instead.
# Support for other distributions can be added as sibling entry points that
# source lib/opencode-common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1090
source "${REPO_ROOT}/lib/opencode-common.sh"

oc_distro_name() {
  printf '%s' "Kali Linux"
}

oc_preflight() {
  local distro_id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    distro_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  fi
  case "$distro_id" in
  kali | debian) ;;
  *)
    warn "This script is designed for Kali Linux (detected: ${distro_id:-unknown})."
    warn "Continuing anyway; use a dedicated entry point for other distributions."
    ;;
  esac
}

oc_ensure_npm_ready() {
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    die 2 "The npm channel needs Node.js and npm, which are not installed.
Install them first with:
  sudo apt update && sudo apt install -y nodejs npm
Or use the dependency-free binary channel instead: --method binary"
  fi
}

opencode_install_main "$@"
