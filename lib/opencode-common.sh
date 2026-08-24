#!/usr/bin/env bash
#
# Shared logic for installing and updating the opencode CLI.
#
# A distro entry point sources this file and may implement these hooks:
#   oc_distro_name       - human readable distro name used in messages
#   oc_preflight         - runs before anything else (distro sanity checks)
#   oc_ensure_npm_ready  - verifies Node.js/npm prerequisites for --method npm
#
# Install channels:
#   binary - official standalone build from https://github.com/anomalyco/opencode,
#            extracted to ~/.opencode/bin (no root required)
#   npm    - "opencode-ai" package managed by npm (needs Node.js)
#
# Security model:
#   - The artifact URL is pinned to the exact release tag whose metadata we
#     parsed (no "latest" redirect race between metadata fetch and download).
#   - The downloaded archive is verified against the sha256 digest published
#     in the GitHub release metadata, fetched over TLS. Missing digests or a
#     mismatch aborts the install (fail closed) before anything is extracted,
#     let alone executed.
#   - We never download-and-pipe a script into bash; extraction happens only
#     after verification. Note honestly: checksums prove integrity in transit,
#     not that upstream itself is malware-free.
#
# Exit codes:
#   0 success / already up to date / not installed (--check-only)
#   1 update available (--check-only)
#   2 usage error, refused prompt, or unrecognized existing install
#   3 could not reach release metadata (rate limit / network)
#   4 checksum verification failed or unsupported target

set -euo pipefail

readonly OC_REPO="anomalyco/opencode"
readonly OC_NPM_PACKAGE="opencode-ai"
readonly OC_BIN_DIR="${HOME}/.opencode/bin"
readonly OC_API_URL="https://api.github.com/repos/${OC_REPO}/releases/latest"

# State filled in by discovery/release helpers.
OC_TMP_DIR=""
OC_RELEASE_TAG=""
OC_RELEASE_VERSION=""

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  local code="$1"
  shift
  printf 'Error: %s\n' "$*" >&2
  exit "$code"
}

need_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die 2 "'$cmd' is required but was not found in PATH."
  fi
}

http_fetch() {
  # http_fetch <url> <output-file>
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 \
    -H "Accept: application/vnd.github+json" -o "$2" "$1"
}

cleanup() {
  if [[ -n "${OC_TMP_DIR:-}" && -d "${OC_TMP_DIR:-}" ]]; then
    rm -rf "$OC_TMP_DIR"
  fi
}

default_oc_tmp_dir() {
  OC_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-install.XXXXXX")"
}

# Distro hooks with safe defaults; entry points may override them.
oc_distro_name() {
  printf '%s' "this distribution"
}

oc_preflight() {
  :
}

oc_ensure_npm_ready() {
  need_cmd node
  need_cmd npm
}

run_hook_if_defined() {
  if declare -F "$1" >/dev/null 2>&1; then
    "$@"
  fi
}

usage() {
  cat <<'EOF'
opencode installer

Usage: install-opencode.sh [options]

Options:
    -h, --help       Show this help text
    -y, --yes        Assume "yes" for all prompts (non-interactive mode)
    --method MODE    Installation channel: auto (default), binary, or npm
    --check-only     Report installed/latest versions and exit
                     (exit 1 when an update is available)

Channels:
    binary  Official standalone build installed to ~/.opencode/bin.
            Always the newest release, no dependencies, no root required.
    npm     The "opencode-ai" npm package. Easier to manage alongside other
            npm tools, but requires Node.js to be installed.

Behaviour:
    - Fresh machines default to the binary channel.
    - An existing install is always updated through its own channel;
      migrating channels requires an explicit --method and confirmation.
    - Updates are announced and confirmed interactively unless -y is given.

Exit codes:
    0 success, already up to date, or nothing installed during --check-only
    1 an update is available (only with --check-only)
    2 usage error, refused prompt, or unrecognized existing install
    3 release metadata unreachable (network / GitHub API rate limit)
    4 checksum verification failed or unsupported platform
EOF
}

normalize_version() {
  # Prints the first dotted number found, e.g. "v1.18.21" -> "1.18.21".
  local raw="$1"
  printf '%s' "$raw" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true
}

version_is_older() {
  # True when $1 sorts strictly before $2 (semantic-ish comparison).
  local a="$1" b="$2"
  [[ "$a" != "$b" ]] && [[ "$a" == "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" ]]
}

fetch_github_release_info() {
  # Populates OC_RELEASE_TAG / OC_RELEASE_VERSION (for callers capturing
  # this function's output) and caches the release JSON under $OC_TMP_DIR.
  #
  # Note: when invoked inside $( ), globals set here are lost, so the cache
  # location is derived from OC_TMP_DIR, which the caller owns.
  local meta="${OC_TMP_DIR}/release.json"
  if ! http_fetch "$OC_API_URL" "$meta"; then
    die 3 "Could not fetch release metadata from ${OC_API_URL}.
This usually means a network problem or an exceeded anonymous GitHub API rate limit.
Try again later, or install through the npm channel: --method npm"
  fi
  OC_RELEASE_TAG="$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$meta" | head -n1)"
  OC_RELEASE_VERSION="$(normalize_version "$OC_RELEASE_TAG")"
  if [[ -z "$OC_RELEASE_VERSION" ]]; then
    die 3 "Release metadata did not contain a usable version tag."
  fi
  printf '%s' "$OC_RELEASE_VERSION"
}

release_asset_digest() {
  # Prints the sha256 digest published for the given asset filename.
  local filename="$1" meta="${OC_TMP_DIR}/release.json" digest=""
  [[ -n "$OC_TMP_DIR" && -f "$meta" ]] || return 0
  digest="$(awk -v fn="$filename" '
    /^[[:space:]]*"name":/ {
      line = $0
      sub(/^[[:space:]]*"name":[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      current = line
    }
    /^[[:space:]]*"digest":/ && current == fn {
      line = $0
      sub(/^[[:space:]]*"digest":[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' "$meta")"
  printf '%s' "${digest#sha256:}"
}

binary_target_filename() {
  # Mirrors the official installer's platform detection:
  # opencode-<os>-<arch>[-baseline][-musl].tar.gz
  local os arch target musl baseline
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -s)" in
  Linux*) os="linux" ;;
  Darwin*) os="darwin" ;;
  esac
  arch="$(uname -m)"
  if [[ "$arch" == "x86_64" ]]; then
    arch="x64"
  elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
    arch="arm64"
  fi
  if [[ "$os" != "linux" && "$os" != "darwin" ]]; then
    die 4 "Unsupported operating system: $(uname -s)"
  fi
  if [[ "$arch" != "x64" && "$arch" != "arm64" ]]; then
    die 4 "Unsupported architecture: $(uname -m)"
  fi
  musl="false"
  baseline="false"
  if [[ "$os" == "linux" ]]; then
    if [[ -f /etc/alpine-release ]] || (ldd --version 2>/dev/null || true) | grep -qi musl; then
      musl="true"
    fi
    if [[ "$arch" == "x64" ]] && ! grep -qwi avx2 /proc/cpuinfo 2>/dev/null; then
      baseline="true"
    fi
  fi
  target="${os}-${arch}"
  if [[ "$baseline" == "true" ]]; then
    target="${target}-baseline"
  fi
  if [[ "$musl" == "true" ]]; then
    target="${target}-musl"
  fi
  printf '%s' "opencode-${target}.tar.gz"
}

find_installation() {
  # Sets OC_INSTALLED_CHANNEL (none|binary|npm|unknown),
  # OC_INSTALLED_PATH and OC_INSTALLED_VERSION.
  local found real version channel="none"
  found="$(command -v opencode 2>/dev/null || true)"
  if [[ -z "$found" && -x "${OC_BIN_DIR}/opencode" ]]; then
    # Not on PATH in this shell yet; the canonical install location counts.
    found="${OC_BIN_DIR}/opencode"
  fi
  OC_INSTALLED_PATH="$found"
  OC_INSTALLED_VERSION=""
  if [[ -n "$found" ]]; then
    real="$(readlink -f "$found" 2>/dev/null || printf '%s' "$found")"
    case "$real" in
    "${HOME}/.opencode/"*)
      channel="binary"
      ;;
    *)
      if command -v npm >/dev/null 2>&1 && npm ls -g "$OC_NPM_PACKAGE" >/dev/null 2>&1; then
        channel="npm"
      else
        channel="unknown"
      fi
      ;;
    esac
    version="$(normalize_version "$("$real" --version 2>/dev/null || true)")"
    OC_INSTALLED_VERSION="$version"
  fi
  OC_INSTALLED_CHANNEL="$channel"
}

latest_version_for_channel() {
  local channel="$1"
  case "$channel" in
  binary)
    fetch_github_release_info
    ;;
  npm)
    npm view "$OC_NPM_PACKAGE" version 2>/dev/null
    ;;
  *)
    die 2 "No update source for channel '$channel'."
    ;;
  esac
}

verified_binary_install() {
  # Downloads the archive for $1, verifies its sha256 against the release
  # metadata, and only then extracts and installs it.
  local version="$1"
  local filename url expected actual extract_dir archive
  filename="$(binary_target_filename)"
  url="https://github.com/${OC_REPO}/releases/download/v${version}/${filename}"
  expected="$(release_asset_digest "$filename")"
  if [[ -z "$expected" ]]; then
    die 4 "No published sha256 digest for ${filename}; refusing to install an unverifiable artifact."
  fi

  log "Installing opencode ${version} (binary channel)..."
  archive="${OC_TMP_DIR}/${filename}"
  extract_dir="${OC_TMP_DIR}/extract"
  mkdir -p "$extract_dir"
  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$archive" "$url"; then
    die 3 "Download failed: ${url}"
  fi
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    die 4 "Checksum mismatch for ${filename}.
Expected: ${expected}
Actual:   ${actual}
The download may be corrupted or tampered with. Nothing was installed."
  fi
  log "Checksum verified (${expected})."

  if ! tar -xzf "$archive" -C "$extract_dir"; then
    die 4 "Failed to extract ${filename}."
  fi
  if [[ ! -f "${extract_dir}/opencode" ]]; then
    die 4 "Archive did not contain the expected 'opencode' binary."
  fi
  mkdir -p "$OC_BIN_DIR"
  mv -f "${extract_dir}/opencode" "${OC_BIN_DIR}/opencode"
  chmod 755 "${OC_BIN_DIR}/opencode"
}

configure_path() {
  # Makes sure $OC_BIN_DIR ends up on PATH for future shells and exports it
  # for the remainder of this one. Idempotent.
  local shell_name config_file="" candidate
  local -a candidates=()
  shell_name="$(basename -- "${SHELL:-bash}")"
  case "$shell_name" in
  fish)
    candidates=("${XDG_CONFIG_HOME:-${HOME}/.config}/fish/config.fish")
    ;;
  zsh)
    candidates=("${ZDOTDIR:-${HOME}}/.zshrc" "${ZDOTDIR:-${HOME}}/.zshenv"
      "${XDG_CONFIG_HOME:-${HOME}/.config}/zsh/.zshrc")
    ;;
  *)
    candidates=("${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.profile")
    ;;
  esac
  if [[ ":$PATH:" != *":${OC_BIN_DIR}:"* ]]; then
    export PATH="${OC_BIN_DIR}:${PATH}"
  fi
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      config_file="$candidate"
      break
    fi
  done
  if [[ -z "$config_file" ]]; then
    warn "No shell configuration file found for ${shell_name}."
    warn "Manually add this directory to your PATH:"
    log "  export PATH=\"${OC_BIN_DIR}:\$PATH\""
    return 0
  fi
  if grep -qsF "$OC_BIN_DIR" "$config_file"; then
    return 0
  fi
  {
    printf '\n'
    printf '# opencode (added by bootstrap)\n'
    if [[ "$shell_name" == "fish" ]]; then
      printf 'fish_add_path %s\n' "$OC_BIN_DIR"
    else
      # shellcheck disable=SC2016
      printf 'export PATH="%s:$PATH"\n' "$OC_BIN_DIR"
    fi
  } >>"$config_file"
  log "Added ${OC_BIN_DIR} to PATH in ${config_file}."
  if [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$OC_BIN_DIR" >>"$GITHUB_PATH"
  fi
}

channel_cleanup_hint() {
  local channel="$1"
  case "$channel" in
  binary) printf 'rm -f "%s/opencode"' "$OC_BIN_DIR" ;;
  npm) printf 'npm uninstall -g %s' "$OC_NPM_PACKAGE" ;;
  esac
}

npm_install_or_update() {
  run_hook_if_defined oc_ensure_npm_ready
  log "Installing opencode via npm (${OC_NPM_PACKAGE}@latest)..."
  if ! npm install -g "${OC_NPM_PACKAGE}@latest"; then
    die 3 "npm installation failed."
  fi
}

confirm() {
  local answer
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die 2 "A confirmation is required but stdin is not interactive. Re-run with -y/--yes to proceed automatically."
  fi
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

report_status() {
  local distro
  distro="$(oc_distro_name)"
  log "opencode installer for ${distro}"
  case "$OC_INSTALLED_CHANNEL" in
  none)
    log "Status: opencode is not installed."
    ;;
  binary | npm)
    log "Status: installed via ${OC_INSTALLED_CHANNEL} channel, version ${OC_INSTALLED_VERSION:-unknown}."
    ;;
  *)
    warn "An 'opencode' command exists at ${OC_INSTALLED_PATH} but its install channel is unrecognized."
    warn "Re-run with an explicit --method binary|--method npm to take over this install."
    ;;
  esac
}

opencode_install_main() {
  ASSUME_YES="0"
  CHECK_ONLY="0"
  METHOD="auto"

  while (($#)); do
    case "$1" in
    -h | --help)
      usage
      return 0
      ;;
    -y | --yes)
      ASSUME_YES="1"
      ;;
    --method)
      [[ $# -ge 2 ]] || die 2 "--method requires a value (auto, binary or npm)."
      METHOD="$2"
      shift
      ;;
    --method=*)
      METHOD="${1#*=}"
      ;;
    --check-only)
      CHECK_ONLY="1"
      ;;
    *)
      usage >&2
      die 2 "Unknown option: $1"
      ;;
    esac
    shift
  done

  case "$METHOD" in
  auto | binary | npm) ;;
  *)
    die 2 "Invalid --method '$METHOD' (expected auto, binary or npm)."
    ;;
  esac

  need_cmd curl
  need_cmd tar
  need_cmd sha256sum
  need_cmd awk
  need_cmd sed
  need_cmd sort

  trap cleanup EXIT INT TERM
  default_oc_tmp_dir
  run_hook_if_defined oc_preflight

  find_installation
  report_status

  # Resolve which channel will own this install.
  local effective_method="$METHOD" latest
  if [[ "$effective_method" == "auto" ]]; then
    case "$OC_INSTALLED_CHANNEL" in
    none) effective_method="binary" ;;
    binary | npm) effective_method="$OC_INSTALLED_CHANNEL" ;;
    *)
      if [[ "$CHECK_ONLY" == "1" ]]; then
        return 2
      fi
      die 2 "The existing opencode install channel could not be determined.
Decide explicitly which manager should own it:
  $0 --method binary   # official standalone build (~/.opencode/bin)
  $0 --method npm      # npm package (requires Node.js)"
      ;;
    esac
  fi

  # The npm channel needs Node.js; give the distro a chance to explain how.
  if [[ "$effective_method" == "npm" ]]; then
    run_hook_if_defined oc_ensure_npm_ready
  fi

  # Never silently switch managers for an existing install.
  if [[ "$OC_INSTALLED_CHANNEL" != "none" && "$OC_INSTALLED_CHANNEL" != "$effective_method" ]]; then
    if [[ "$CHECK_ONLY" == "1" ]]; then
      log "Installed via '${OC_INSTALLED_CHANNEL}' but --method '${effective_method}' was requested; skipping changes in --check-only mode."
      return 2
    fi
    log "This machine already has opencode from the '${OC_INSTALLED_CHANNEL}' channel."
    log "Installing via '${effective_method}' will leave that copy in place; remove it later with:"
    log "  $(channel_cleanup_hint "$OC_INSTALLED_CHANNEL")"
    if ! confirm "Continue installing via '${effective_method}'?"; then
      log "Aborted. The existing install was not touched."
      return 0
    fi
    OC_PREVIOUS_CHANNEL="$OC_INSTALLED_CHANNEL"
  fi

  latest="$(latest_version_for_channel "$effective_method")"
  if [[ -z "$latest" ]]; then
    die 3 "Could not determine the latest released version."
  fi
  log "Latest available version: ${latest}"

  if [[ "$CHECK_ONLY" == "1" ]]; then
    if [[ "$OC_INSTALLED_CHANNEL" == "none" ]]; then
      return 0
    fi
    if [[ -z "$OC_INSTALLED_VERSION" ]]; then
      warn "Installed version could not be determined; cannot compare against ${latest}."
      return 1
    fi
    if version_is_older "$OC_INSTALLED_VERSION" "$latest"; then
      log "Update available: ${OC_INSTALLED_VERSION} -> ${latest}"
      return 1
    fi
    log "opencode is up to date (${OC_INSTALLED_VERSION})."
    return 0
  fi

  if [[ "$OC_INSTALLED_CHANNEL" != "none" && -n "$OC_INSTALLED_VERSION" ]]; then
    if ! version_is_older "$OC_INSTALLED_VERSION" "$latest"; then
      log "opencode is already up to date (${OC_INSTALLED_VERSION}). Nothing to do."
      return 0
    fi
    if ! confirm "Upgrade opencode from ${OC_INSTALLED_VERSION} to ${latest}?"; then
      log "Upgrade declined; keeping ${OC_INSTALLED_VERSION}."
      return 0
    fi
  fi

  case "$effective_method" in
  binary)
    verified_binary_install "$latest"
    configure_path
    ;;
  npm)
    npm_install_or_update
    ;;
  esac

  # Refresh lookup for the verification step below.
  hash -r 2>/dev/null || true
  if [[ -x "${OC_BIN_DIR}/opencode" ]]; then
    OC_INSTALLED_PATH="${OC_BIN_DIR}/opencode"
  else
    OC_INSTALLED_PATH="$(command -v opencode 2>/dev/null || true)"
  fi
  if [[ -z "$OC_INSTALLED_PATH" || ! -x "$OC_INSTALLED_PATH" ]]; then
    die 3 "Installation finished but the opencode binary could not be located."
  fi
  local final_version
  final_version="$(normalize_version "$("$OC_INSTALLED_PATH" --version 2>/dev/null || true)")"
  if [[ -z "$final_version" ]]; then
    die 3 "'$OC_INSTALLED_PATH --version' produced no output; installation looks broken."
  fi
  log "opencode ${final_version} is installed and working (${effective_method} channel)."
  if [[ "$final_version" != "$latest" ]]; then
    warn "Installed version ${final_version} differs from expected ${latest}."
  fi
  if [[ -n "${OC_PREVIOUS_CHANNEL:-}" && "$OC_PREVIOUS_CHANNEL" != "$effective_method" ]]; then
    log "Note: the previous '${OC_PREVIOUS_CHANNEL}' install still exists; remove it with:"
    log "  $(channel_cleanup_hint "$OC_PREVIOUS_CHANNEL")"
  fi
  log "Run 'opencode' inside a project directory to get started."
}
