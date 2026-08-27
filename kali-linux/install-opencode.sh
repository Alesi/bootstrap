#!/bin/bash

# Kali Linux installer for the opencode CLI.
#
# Key behaviors:
#   1. Fresh install  -> official installer (https://opencode.ai/install), binary in ~/.opencode/bin
#   2. Already there  -> stays on the channel it was installed with (never silently switches).
#   3. npm opt-in    -> --method npm (needs nodejs + npm; fails with a clear message otherwise).
#   4. Idempotent    -> safe to re-run: detects version, compares to latest, asks [y/N] before updating.
#   5. Integrity    -> download to temp file, verify (published checksum if any, else byte-identical
#                      cross-check against an independent official mirror), fail closed. This proves transport
#                      integrity, NOT "this binary is malware-free". Source review is outside this script's scope.
#   6. No root needed. (Inverse of install-git.sh.)

# Resolve the shared library's location without assuming a cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

if [[ ! -f "$LIB_DIR/install-opencode-common.sh" ]]; then
  echo "[opencode] ERROR: Shared library not found at $LIB_DIR/install-opencode-common.sh" >&2
  exit 1
fi

# shellcheck source=lib/install-opencode-common.sh
source "$LIB_DIR/install-opencode-common.sh"

# Distro-specific configuration.
# shellcheck disable=SC2034 # documented, informational
DISTRO_NAME="Kali Linux"
INSTALL_HINTS="Install Node.js and npm first (e.g. 'sudo apt install nodejs npm'), then re-run."

RC_FILES=()
for rc_name in .bashrc .zshrc; do
  if [[ -f "$HOME/$rc_name" ]]; then
    RC_FILES+=("$HOME/$rc_name")
  fi
done

# ---------------------------------------------------------------------------
# Parse flags.
#   -y/--yes, -m/--method, -c/--check-only, -h/--help
# ---------------------------------------------------------------------------
METHOD="auto"
YES=0
CHECK_ONLY=0
HELP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      YES=1
      ;;
    -m|--method)
      shift
      case "${1:-}" in
        installer|npm|auto)
          METHOD="$1"
          ;;
        *)
          echo "[opencode] ERROR: --method must be one of: installer | npm | auto" >&2
          exit 1
          ;;
      esac
      ;;
    --method=*)
      VALUE="${1#--method=}"
      case "$VALUE" in
        installer|npm|auto)
          METHOD="$VALUE"
          ;;
        *)
          echo "[opencode] ERROR: --method must be one of: installer | npm | auto" >&2
          exit 1
          ;;
      esac
      ;;
    -c|--check-only)
      CHECK_ONLY=1
      ;;
    -h|--help)
      HELP=1
      ;;
    *)
      echo "[opencode] ERROR: Unknown option: $1" >&2
      echo "[opencode] Try --help." >&2
      exit 1
      ;;
  esac
  shift
done

open_install_log

if [[ "$HELP" -eq 1 ]]; then
  opencode_print_help
  exit 0
fi

# No root required. Warn if run as root, but don't demand sudo.
if [[ "${EUID}" -eq 0 ]]; then
  opencode_warn "Running as root. This script is designed for user-level installs."
fi

# Delegate to the shared main.
opencode_main
