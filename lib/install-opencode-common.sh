#!/bin/bash
#
# Shared functions for installing/updating the opencode CLI.
# Sourced by per-distro entry points (e.g. kali-linux/install-opencode.sh).
#
# Security scope:
#   This script verifies transport integrity and cross-source consistency of
#   the installer script. It does NOT guarantee the upstream installer is
#   free of malware — that risk is residual and documented here.
#   Checksums prove the bytes matched at download time, not that the code
#   is safe to run.

set -u -o pipefail

# ── Constants ────────────────────────────────────────────────────────────────
OPENCODE_INSTALLER_URL="https://opencode.ai/install"
OPENCODE_INSTALLER_MIRROR="https://raw.githubusercontent.com/anomalyco/opencode/refs/heads/master/install"
OPENCODE_GITHUB_API="https://api.github.com/repos/anomalyco/opencode/releases/latest"
OPENCODE_DEFAULT_BIN_DIR="$HOME/.opencode/bin"
OPENCODE_NPM_PACKAGE="opencode-ai"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()  { echo "[opencode] $*"; }
warn()  { echo "[opencode] WARNING: $*" >&2; }
error() { echo "[opencode] ERROR: $*" >&2; }
die()   { error "$@"; exit 1; }

# Strip leading 'v' from a version string: v1.2.3 → 1.2.3
strip_v_prefix() {
  local ver="$1"
  echo "${ver#v}"
}

# Compare two dotted version strings (simple numeric comparison).
# Returns 0 if $1 >= $2, 1 otherwise.
version_gte() {
  local IFS='.'
  read -ra a <<< "$1"
  read -ra b <<< "$2"
  local len=${#a[@]}
  if (( ${#b[@]} > len )); then
    len=${#b[@]}
  fi
  for (( i = 0; i < len; i++ )); do
    local na=${a[i]:-0}
    local nb=${b[i]:-0}
    if (( na > nb )); then
      return 0
    fi
    if (( na < nb )); then
      return 1
    fi
  done
  return 0
}

# ── Channel detection ────────────────────────────────────────────────────────

# Detect how opencode is currently installed.
# Prints: "installer", "npm", or "none"
detect_channel() {
  local resolved
  resolved="$(readlink -f "$(command -v opencode 2>/dev/null)" 2>/dev/null || true)"

  if [[ -z "$resolved" ]]; then
    echo "none"
    return
  fi

  case "$resolved" in
    "$HOME/.opencode/bin/"*)  echo "installer" ;;
    *node_modules*|*npm*|*npx*) echo "npm" ;;
    *)
      # Fallback: if it lives under ~/.opencode/bin it's installer-managed
      if [[ "$resolved" == "$HOME/.opencode/bin/opencode" ]]; then
        echo "installer"
      else
        echo "unknown"
      fi
      ;;
  esac
}

# Get the installed version string (without 'v' prefix). Prints empty if not found.
installed_version() {
  if command -v opencode &>/dev/null; then
    local raw
    raw="$(opencode --version 2>/dev/null || true)"
    raw="$(echo "$raw" | tr -d '[:space:]')"
    strip_v_prefix "$raw"
  fi
}

# ── GitHub API ───────────────────────────────────────────────────────────────

# Fetch the latest release tag from GitHub. Handles rate-limit gracefully.
# Prints the raw tag (e.g. "v1.2.3") or empty on failure.
github_latest_tag() {
  local token_header=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    token_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  local response
  response="$(curl -fsSL --retry 2 --retry-delay 3 \
    -H "Accept: application/vnd.github+json" \
    "${token_header[@]}" \
    "$OPENCODE_GITHUB_API" 2>/dev/null)" || {
    warn "Could not fetch latest release from GitHub API (rate-limited or network error)."
    echo ""
    return
  }
  local tag
  tag="$(echo "$response" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' || true)"
  echo "$tag"
}

# ── Integrity verification ───────────────────────────────────────────────────

# Download installer script to a temp file. Prints the temp path.
# Caller is responsible for deleting the file.
download_installer() {
  local tmpfile
  tmpfile="$(mktemp /tmp/opencode-install.XXXXXX.sh)"

  if ! curl -fsSL --retry 2 --retry-delay 3 -o "$tmpfile" "$OPENCODE_INSTALLER_URL"; then
    rm -f "$tmpfile"
    die "Failed to download installer from $OPENCODE_INSTALLER_URL"
  fi
  echo "$tmpfile"
}

# Verify the installer by comparing it byte-for-byte against the official mirror.
# Both sources are pinned to official domains. Fail-closed on any mismatch.
verify_installer() {
  local primary="$1"
  local primary_hash
  primary_hash="$(sha256sum "$primary" | awk '{print $1}')"

  info "Primary installer hash: $primary_hash"

  local mirror
  mirror="$(mktemp /tmp/opencode-mirror.XXXXXX.sh)"

  if ! curl -fsSL --retry 2 --retry-delay 3 -o "$mirror" "$OPENCODE_INSTALLER_MIRROR"; then
    rm -f "$mirror"
    die "Failed to download mirror from $OPENCODE_INSTALLER_MIRROR — cannot verify integrity."
  fi

  local mirror_hash
  mirror_hash="$(sha256sum "$mirror" | awk '{print $1}')"
  rm -f "$mirror"

  if [[ "$primary_hash" != "$mirror_hash" ]]; then
    die "Integrity check FAILED: installer ($primary_hash) differs from mirror ($mirror_hash). Refusing to execute."
  fi

  info "Integrity check passed: installer and mirror are byte-identical."
}

# ── Method resolution ────────────────────────────────────────────────────────

# Resolve which install method to use.
#   $1 = requested method ("auto", "installer", "npm")
#   $2 = current channel ("none", "installer", "npm")
# Prints the chosen method and exits non-zero on conflict.
resolve_method() {
  local requested="$1"
  local current="$2"

  if [[ "$requested" == "auto" ]]; then
    if [[ "$current" == "none" ]]; then
      echo "installer"
    elif [[ "$current" == "unknown" ]]; then
      warn "Could not determine install channel — defaulting to official installer."
      echo "installer"
    else
      echo "$current"
    fi
    return
  fi

  # User explicitly chose a method
  if [[ "$current" != "none" && "$requested" != "$current" ]]; then
    warn "Currently installed via '$current' but you requested '$requested'."
    warn "Switching channels may leave orphaned files. Proceed only if you intend to migrate."
  fi
  echo "$requested"
}

# ── PATH management ──────────────────────────────────────────────────────────

# Ensure ~/.opencode/bin is on PATH for the current session.
ensure_path_current() {
  if [[ ":$PATH:" != *":$OPENCODE_DEFAULT_BIN_DIR:"* ]]; then
    export PATH="$OPENCODE_DEFAULT_BIN_DIR:$PATH"
  fi
}

# Add ~/.opencode/bin to shell rc files idempotently.
ensure_path_persistent() {
  local rc_files=()
  [[ -f "$HOME/.bashrc" ]] && rc_files+=("$HOME/.bashrc")
  [[ -f "$HOME/.zshrc" ]]  && rc_files+=("$HOME/.zshrc")

  local marker="# opencode bin path"
  local line="export PATH=\"$OPENCODE_DEFAULT_BIN_DIR:\$PATH\""

  for rc in "${rc_files[@]}"; do
    if ! grep -qF "$marker" "$rc" 2>/dev/null; then
      printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
      info "Added PATH entry to $rc"
    fi
  done
}

# ── Installation channels ────────────────────────────────────────────────────

# Run the official installer with integrity verification.
#   $1 = extra arguments for the installer (e.g. --no-modify-path)
run_installer() {
  local extra_args=("$@")
  info "Downloading opencode installer..."
  local installer
  installer="$(download_installer)"

  info "Verifying installer integrity..."
  verify_installer "$installer"

  info "Running installer..."
  bash "$installer" "${extra_args[@]}"
  local rc=$?
  rm -f "$installer"
  if (( rc != 0 )); then
    die "Installer exited with code $rc"
  fi

  ensure_path_current
  ensure_path_persistent
}

# Install via npm.
#   $1 = "yes" to skip prompts
install_npm() {
  if ! command -v npm &>/dev/null; then
    die "npm is not installed. Install Node.js and npm first, or use --method installer."
  fi
  info "Installing $OPENCODE_NPM_PACKAGE via npm..."
  npm install -g "$OPENCODE_NPM_PACKAGE"
}

# ── Update logic ─────────────────────────────────────────────────────────────

# Check if an update is available and prompt (or auto-accept with $YES).
#   $1 = "yes" to auto-accept, "no" to prompt
#   $2 = non-zero exit code for check-only when update available
check_and_update() {
  local auto_yes="$1"
  local installed
  installed="$(installed_version)"
  local latest_raw
  latest_raw="$(github_latest_tag)"

  if [[ -z "$installed" ]]; then
    die "opencode does not appear to be installed."
  fi

  if [[ -z "$latest_raw" ]]; then
    warn "Could not determine latest version. Skipping update check."
    return 0
  fi

  local latest
  latest="$(strip_v_prefix "$latest_raw")"

  if version_gte "$installed" "$latest"; then
    info "Already up to date (installed: $installed, latest: $latest)."
    return 0
  fi

  info "Update available: $installed → $latest"

  if [[ "$auto_yes" == "yes" ]]; then
    info "Auto-accepting update (-y)."
  else
    read -rp "Update to version $latest? [y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      info "Update declined."
      return 0
    fi
  fi

  local channel
  channel="$(detect_channel)"

  case "$channel" in
    installer)
      run_installer --no-modify-path
      ;;
    npm)
      install_npm
      ;;
    *)
      die "Cannot update: unrecognized install channel '$channel'. Manually reinstall or use --method."
      ;;
  esac

  info "Update complete. New version: $(installed_version)"
}
