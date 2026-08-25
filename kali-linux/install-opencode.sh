#!/bin/bash
#
# Install or update the opencode CLI on Kali Linux.
#
# Usage:
#   bash kali-linux/install-opencode.sh [OPTIONS]
#
# Options:
#   -y, --yes            Auto-accept prompts (non-interactive).
#   --method <method>    Install method: "installer" (default) or "npm".
#                        On fresh installs, defaults to the official installer.
#                        On existing installs, sticks to the detected channel.
#   --check-only         Check for updates and exit. Exit 0 if up-to-date,
#                        exit 1 if update available or not installed.
#   --no-modify-path     Pass --no-modify-path to the official installer.
#   -h, --help           Show this help message.
#
# No root required — this is a user-level installer.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"

# Source shared library
if [[ ! -f "$LIB_DIR/install-opencode-common.sh" ]]; then
  die "Shared library not found at $LIB_DIR/install-opencode-common.sh"
fi
# shellcheck source=../lib/install-opencode-common.sh
source "$LIB_DIR/install-opencode-common.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────
METHOD="auto"
YES="no"
CHECK_ONLY="no"
INSTALLER_EXTRA_ARGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install or update the opencode CLI on Kali Linux.

Options:
  -y, --yes            Auto-accept prompts (non-interactive).
  --method <method>    Install method: "installer" (default) or "npm".
                       On fresh installs, defaults to the official installer.
                       On existing installs, sticks to the detected channel.
  --check-only         Check for updates and exit. Exit 0 if up-to-date,
                       exit 1 if update available or not installed.
  --no-modify-path     Pass --no-modify-path to the official installer.
  -h, --help           Show this help message.

No root required.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      YES="yes"
      shift
      ;;
    --method)
      [[ $# -lt 2 ]] && die "Missing value for --method"
      METHOD="$2"
      shift 2
      ;;
    --check-only)
      CHECK_ONLY="yes"
      shift
      ;;
    --no-modify-path)
      INSTALLER_EXTRA_ARGS+=("--no-modify-path")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (see --help)"
      ;;
  esac
done

# Validate method
if [[ "$METHOD" != "auto" && "$METHOD" != "installer" && "$METHOD" != "npm" ]]; then
  die "Invalid --method: $METHOD (must be 'installer' or 'npm')"
fi

# ── Warn if running as root ──────────────────────────────────────────────────
if [[ "${EUID:-0}" -eq 0 ]]; then
  warn "Running as root is not recommended for user-level installation."
fi

# ── Detect current state ─────────────────────────────────────────────────────
CURRENT_CHANNEL="$(detect_channel)"
CURRENT_VERSION="$(installed_version)"

if [[ "$CURRENT_CHANNEL" != "none" ]]; then
  info "Detected existing install: channel=$CURRENT_CHANNEL, version=$CURRENT_VERSION"
else
  info "No existing opencode installation detected."
fi

# ── Check-only mode ──────────────────────────────────────────────────────────
if [[ "$CHECK_ONLY" == "yes" ]]; then
  if [[ "$CURRENT_CHANNEL" == "none" ]]; then
    error "opencode is not installed."
    exit 1
  fi
  LATEST_RAW="$(github_latest_tag)"
  if [[ -z "$LATEST_RAW" ]]; then
    error "Could not determine latest version."
    exit 1
  fi
  LATEST="$(strip_v_prefix "$LATEST_RAW")"
  if version_gte "$CURRENT_VERSION" "$LATEST"; then
    info "Up to date (installed: $CURRENT_VERSION, latest: $LATEST)."
    exit 0
  else
    info "Update available: $CURRENT_VERSION → $LATEST"
    exit 1
  fi
fi

# ── Resolve method ───────────────────────────────────────────────────────────
RESOLVED_METHOD="$(resolve_method "$METHOD" "$CURRENT_CHANNEL")"
info "Install method: $RESOLVED_METHOD"

# ── Fresh install or update ──────────────────────────────────────────────────
if [[ "$CURRENT_CHANNEL" == "none" ]]; then
  # Fresh install
  info "Installing opencode via $RESOLVED_METHOD..."

  case "$RESOLVED_METHOD" in
    installer)
      ensure_path_current
      run_installer "${INSTALLER_EXTRA_ARGS[@]}"
      ;;
    npm)
      install_npm
      ;;
  esac

  info "Installation complete. Version: $(installed_version)"
else
  # Existing install — check for updates
  check_and_update "$YES"
fi
