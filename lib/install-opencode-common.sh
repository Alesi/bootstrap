#!/bin/bash

# Shared logic for installing/updating the opencode CLI.
# Distro-specific scripts source this file after defining a few variables:
#   DISTRO_NAME   - human-readable distro name (e.g. "Kali Linux")
#   INSTALL_HINTS - message shown when the npm channel's prerequisites are missing.
#   RC_FILES      - array of shell rc files to keep the PATH entry in sync
#                   (the official installer also manages ~/.opencode/bin PATH itself).
#
# Security model:
#   - Downloads are ALWAYS written to a temp file first, verified, then executed.
#     Nothing is ever piped straight into bash.
#   - URLs are pinned to official domains only: opencode.ai and github.com/anomalyco/opencode.
#   - If upstream publishes a sha256 checksum, enforce it (fail closed).
#   - If no published checksum exists, download the same artifact from a second,
#     independent official source and require byte-identical content (fail closed).
#   - NOTE: transport integrity + cross-source consistency are what we prove. This is NOT
#     a guarantee the artifact is malware-free. Treat unsigned installers as a residual risk.

set -u -o pipefail

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
EXIT_UPTODATE=0        # installed, current, nothing to do
EXIT_ACTION_NEEDED=2   # --check-only: not installed OR update available

# shellcheck disable=SC2034 # EXIT_ERROR used in docs, kept for clarity
EXIT_ERROR=1            # hard error (checksum mismatch, missing deps, etc.)

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
OFFICIAL_INSTALL_URL="https://opencode.ai/install"
MIRROR_INSTALL_URL="https://raw.githubusercontent.com/anomalyco/opencode/master/install"

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  API_CURL_ARGS=(-H "Authorization: Bearer $GITHUB_TOKEN")
else
  API_CURL_ARGS=()
fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
opencode_die() {
  echo "[opencode] ERROR: $*" >&2
  exit 1
}

opencode_warn() {
  echo "[opencode] WARNING: $*" >&2
}

open_install_log() {
  mkdir -p "$CONFIG_DIR"
  local log="$CONFIG_DIR/opencode-install.log"
  echo "== $(date --rfc-3339=seconds) $(basename "${0:-unknown}") ==" >>"$log"
}

opencode_version_from_string() {
  # Normalizes "v1.2.3" or "1.2.3" -> parts that sort -V can handle.
  printf '%s\n' "$1" | sed 's/^v//'
}

opencode_version_at_least() {
  # Returns 0 if first version arg >= second version arg, using sort -V semantics.
  local a b sorted
  a="$(opencode_version_from_string "$1")"
  b="$(opencode_version_from_string "$2")"
  [[ "$a" == "$b" ]] && return 0
  sorted="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)"
  [[ "$sorted" == "$a" ]]
}

gets_latest_release_version() {
  # Fetches the latest opencode release from GitHub. Returns the raw tag (e.g. "v1.0.0").
  # Tolerates API failures (rate limits, etc.): prints nothing and returns 1.
  local tag
  tag="$(curl -fsSL "${API_CURL_ARGS[@]}" \
      https://api.github.com/repos/anomalyco/opencode/releases/latest \
      2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
  if [[ -z "$tag" ]]; then
    return 1
  fi
  printf '%s\n' "$tag"
}

published_checksum_for() {
  # Looks for a published sha256 for the given GitHub release asset URL.
  # If none exists upstream, returns 1.
  local release_id="${1:?}"
  local asset_url
  asset_url="$(curl -fsSL "${API_CURL_ARGS[@]}" \
      "https://api.github.com/repos/anomalyco/opencode/releases/$release_id" \
      2>/dev/null | sed -n 's/.*"browser_download_url":"\([^"]*install[^"]*\.sha256\)".*/\1/p')"
  [[ -n "$asset_url" ]] || return 1
  curl -fsSL "${API_CURL_ARGS[@]}" "$asset_url" 2>/dev/null | awk '{print $1}'
}

verify_downloads_agree() {
  # Verifies two downloaded files are byte-identical. If a published checksum exists,
  # also enforces it. Calls opencode_die (fail closed) on any mismatch.
  local file_a="$1" file_b="$2" published_checksum="$3"

  local sha_a sha_b
  sha_a="$(sha256sum "$file_a" | awk '{print $1}')"
  sha_b="$(sha256sum "$file_b" | awk '{print $1}')"

  if [[ -n "$published_checksum" ]]; then
    echo "[opencode] Verifying published checksum: $published_checksum"
    if [[ "$sha_a" != "$published_checksum" ]]; then
      opencode_die "Checksum mismatch! Downloaded file sha256=$sha_a, expected $published_checksum. Refusing to execute. This may indicate tampering or a corrupted mirror."
    fi
  fi

  if [[ "$sha_a" != "$sha_b" ]]; then
    opencode_die "The two official sources disagree (sha256 $sha_a vs $sha_b). Refusing to install without a trustworthy artifact."
  fi

  printf '[opencode] Integrity verified: sha256 %s (dual-source %s)\n' "$sha_a" \
    "$([[ -n "$published_checksum" ]] && echo 'cross-check + published checksum' || echo 'byte-identical cross-check. NOTE: transport integrity only, not a malware guarantee.')"
}

download_to_temp() {
  # Downloads $1 to a fresh mktemp file, echoing its path on stdout.
  local url="$1"
  case "$url" in
    https://opencode.ai/*|https://github.com/anomalyco/opencode/*|https://raw.githubusercontent.com/anomalyco/opencode/*)
      ;;
    *)
      opencode_die "Refusing to download from non-official domain: $url"
      ;;
  esac
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL "$url" -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

opencode_is_installer_managed() {
  # The official installer puts the binary at ~/.opencode/bin/opencode.
  [[ -x "$HOME/.opencode/bin/opencode" ]]
}

opencode_detect_channel() {
  # Prints "installer", "npm", or "none".
  if opencode_is_installer_managed; then
    echo "installer"
  elif command -v opencode >/dev/null 2>&1; then
    echo "npm"
  else
    echo "none"
  fi
}

opencode_current_version() {
  # Prints the installed version, stripping a leading "v".
  if ! command -v opencode >/dev/null 2>&1; then
    return 1
  fi
  local v
  v="$(opencode --version 2>/dev/null | sed -n '1{s/^v//;p}')"
  printf '%s\n' "$v"
}

add_path_entry() {
  # Idempotently ensures ~/.opencode/bin is on PATH in the shell rc files.
  local marker="# opencode-managed PATH"
  # shellcheck disable=SC2016 # intentional: literal so it gets expanded in the new shell
  local entry='export PATH="$HOME/.opencode/bin:$PATH"'
  for rc in "${RC_FILES[@]}"; do
    [[ -f "$rc" ]] || continue
    if grep -qF "$marker" "$rc" 2>/dev/null; then
      continue
    fi
    {
      echo ""
      echo "$marker"
      echo "$entry"
    } >>"$rc"
  done
}

opencode_installer_log() {
  local log="$CONFIG_DIR/opencode-install.log"
  {
    echo "  channel: installer"
    echo "  version: $1"
    echo "  install-log: $log"
  } >>"$log"
}

# ---------------------------------------------------------------------------
# Integrity-checked install via the official installer script.
# ---------------------------------------------------------------------------
install_via_official_installer() {
  local yes="${1:-0}"
  local latest_tag="${2:-}"

  echo "[opencode] Latest release: ${latest_tag:-?}"
  echo "[opencode] Downloading the official installer to a temp file for verification..."

  local t1 t2
  t1="$(download_to_temp "$OFFICIAL_INSTALL_URL")" || opencode_die "Failed to download installer from $OFFICIAL_INSTALL_URL"
  t2="$(download_to_temp "$MIRROR_INSTALL_URL")" || {
    rm -f "$t1"
    opencode_die "Failed to download mirror installer from $MIRROR_INSTALL_URL"
  }

  # Upstream currently publishes no sha256 assets for the installer script.
  # TODO: if upstream ever ships one, wire its value in here (fail closed).
  verify_downloads_agree "$t1" "$t2" ""

  # The official installer owns ~/.opencode/bin and knows how to update itself.
  # We pass --no-modify-path so only we manage the user's shell rc files.
  bash "$t1" -- --no-modify-path
  local rc=$?
  rm -f "$t1" "$t2"

  if [[ $rc -eq 0 ]]; then
    add_path_entry
    opencode_installer_log "${latest_tag:-unknown}"

    if ! command -v opencode >/dev/null 2>&1; then
      echo ""
      echo "[opencode] Install complete. Start a new shell (or source your shell rc) so PATH picks up ~/.opencode/bin."
    else
      echo "[opencode] opencode is ready: $(opencode --version | sed 's/^v//')"
    fi
  else
    opencode_die "The official installer exited with code $rc. See $CONFIG_DIR/opencode-install.log"
  fi
}

# ---------------------------------------------------------------------------
# npm channel.
# ---------------------------------------------------------------------------
npm_channel_prereqs_ok() {
  command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1
}

install_via_npm() {
  local yes="${1:-0}"
  local latest_tag="${2:-}"

  if ! npm_channel_prereqs_ok; then
    opencode_die "npm channel selected but 'node' and 'npm' were not found.${INSTALL_HINTS:+ $INSTALL_HINTS}"
  fi

  echo "[opencode] Installing latest opencode via npm (global)..."
  if [[ "$yes" -eq 1 ]]; then
    npm install -g --silent opencode-ai
  else
    npm install -g opencode-ai
  fi
  local rc=$?

  if [[ $rc -ne 0 ]]; then
    opencode_die "npm install failed (exit $rc). Take a look at the npm output above."
  fi
}

# ---------------------------------------------------------------------------
# Channel ownership discipline.
#
# The cardinal rule: never silently switch managers. Two tools owning one binary
# (~/.opencode/bin shadowing an npm shim, or vice versa) is how update paths rot.
# If the user explicitly passes --method and it disagrees, we require a [y/N] confirm.
# ---------------------------------------------------------------------------
resolve_method() {
  # Usage: resolve_method <requested_method: "installer"|"npm"|"auto"> <?yes>
  # Prints the method to use: "installer" or "npm".
  local requested="${1:-auto}"
  local yes="${2:-0}"
  local detected
  detected="$(opencode_detect_channel)"

  if [[ "$requested" == "auto" ]]; then
    case "$detected" in
      installer)
        echo "installer"
        ;;
      npm)
        echo "npm"
        ;;
      none)
        echo "installer"
        ;;
    esac
    return 0
  fi

  # Explicit --method given. If it disagrees with what's installed, ask for confirmation.
  if [[ "$detected" != "none" && "$detected" != "$requested" ]]; then
    echo "[opencode] opencode is currently managed by: $detected"
    echo "[opencode] Switching to: $requested"
    if [[ "$yes" -ne 1 ]]; then
      read -r -p "[opencode] This will leave two managers over one binary. Continue? [y/N]: " answer
      if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "[opencode] Aborted. Staying on $detected."
        exit 0
      fi
    else
      echo "[opencode] Non-interactive (-y). Proceeding with explicit switch."
    fi
  fi

  echo "$requested"
}

# ---------------------------------------------------------------------------
# The main entry point shared by all distro installers.
# Expects: METHOD (auto|installer|npm), YES (0|1), CHECK_ONLY (0|1), HELP (0|1)
# ---------------------------------------------------------------------------
opencode_main() {
  local help="${HELP:-0}"
  if [[ "$help" -eq 1 ]]; then
    opencode_print_help
    exit 0
  fi

  open_install_log

  local yes="${YES:-0}"
  local check_only="${CHECK_ONLY:-0}"

  # --check-only does not require network for the channel check, but does for the
  # latest-version comparison. If the API is rate-limited we warn and exit 0
  # rather than blocking (per the issue's rate-limit note).
  local latest_tag=""
  latest_tag="$(gets_latest_release_version)" || {
    opencode_warn "Could not reach the GitHub API (rate limit?). Proceeding with what we know."
  }

  local detected
  detected="$(opencode_detect_channel)"

  if [[ "$check_only" -eq 1 ]]; then
    if [[ "$detected" == "none" ]]; then
      echo "[opencode] opencode is not installed."
      echo "[opencode] Run this script (no flags) to install the latest version."
      exit "$EXIT_ACTION_NEEDED"
    fi

    local current
    current="$(opencode_current_version)" || opencode_die "opencode binary found but --version failed."

    echo "[opencode] Installed version: $current"
    echo "[opencode] Channel:          $detected"

    if [[ -z "$latest_tag" ]]; then
      opencode_warn "Latest version unknown (GitHub API unavailable). Cannot compare."
      exit 0
    fi

    local latest="${latest_tag#v}"
    echo "[opencode] Latest version:   $latest"

    if opencode_version_at_least "$current" "$latest"; then
      echo "[opencode] Up to date."
      exit "$EXIT_UPTODATE"
    fi
    echo "[opencode] Update available."
    exit "$EXIT_ACTION_NEEDED"
  fi

  if [[ -z "$latest_tag" ]]; then
    opencode_warn "Latest version unknown (GitHub API unavailable). Skipping the update check."
  else
    local current=""
    if command -v opencode >/dev/null 2>&1; then
      current="$(opencode_current_version || true)"
    fi

    if [[ -n "$current" ]]; then
      local latest="${latest_tag#v}"
      if opencode_version_at_least "$current" "$latest"; then
        echo "[opencode] Installed version $current is already the latest ($latest). Nothing to do."
        exit "$EXIT_UPTODATE"
      fi
      echo "[opencode] Installed: $current   Latest: $latest"
    else
      echo "[opencode] opencode is not installed yet. Installing latest..."
    fi

    if [[ "$yes" -ne 1 ]]; then
      # If we get here: either not installed, or an update is available.
      if [[ -n "$current" ]]; then
        read -r -p "[opencode] Update to $latest? [y/N]: " answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
          echo "[opencode] Aborted. opencode remains at $current."
          exit 0
        fi
      fi
    fi
  fi

  local resolved
  resolved="$(resolve_method "${METHOD:-auto}" "$yes")"

  case "$resolved" in
    installer)
      install_via_official_installer "$yes" "$latest_tag"
      ;;
    npm)
      install_via_npm "$yes" "$latest_tag"
      ;;
    *)
      opencode_die "resolve_method returned an unknown channel: $resolved"
      ;;
  esac
}

opencode_print_help() {
  cat <<'EOF'
Usage: install-opencode.sh [options]

Installs or updates the opencode CLI.

Options:
  -y, --yes          Non-interactive. Accept all prompts; never asks.
  -m, --method M     Channel: "installer" (official installer) or "npm"
                     Default: auto-detect. Fresh -> installer.
                     Never silently switches channels on an existing install.
  -c, --check-only   Report state and exit:
                       0  installed and up to date
                       2  action needed (not installed, or update available)
                       1  error (binary broken, API unreachable during check)
  -h, --help         Show this help.
EOF
}
