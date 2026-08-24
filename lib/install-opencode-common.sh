#!/usr/bin/env bash
# Shared logic for installing/updating opencode.
# Distro-agnostic on purpose: distro scripts (kali-linux/, arch-linux/, ...)
# source this file and provide the distro-specific bits (prereq hints,
# shell rc files, final messages).
#
# Security model (honest scope):
# - All downloads happen over TLS to pinned official domains only.
# - The official installer is downloaded to a temp file, never piped to bash.
# - If the GitHub release publishes checksum assets covering a file we
#   download, the sha256 must match or we abort (fail closed).
# - Upstream currently publishes NO checksums for the CLI artifacts, so the
#   installer is additionally cross-checked between two independent official
#   sources (opencode.ai CDN and raw.githubusercontent.com of the official
#   repo). A mismatch or failed fetch aborts (fail closed).
# - Checksum/mirror checks prove transport integrity and cross-source
#   consistency. They CANNOT rule out compromise of upstream itself. No
#   download-based method can; scripts that claim otherwise are lying.

set -u -o pipefail

OC_REPO="anomalyco/opencode"
OC_INSTALLER_URL="https://opencode.ai/install"
OC_INSTALLER_MIRROR="https://raw.githubusercontent.com/${OC_REPO}/master/install"
# shellcheck disable=SC2034 # used by distro scripts sourcing this file
OC_BIN_DIR="${HOME}/.opencode/bin"
# shellcheck disable=SC2034 # used by distro scripts sourcing this file
OC_NPM_PACKAGE="opencode-ai"
OC_API_LATEST="https://api.github.com/repos/${OC_REPO}/releases/latest"

# shellcheck disable=SC2034 # used by distro scripts sourcing this file
ASSUME_YES=false
# shellcheck disable=SC2034 # used by distro scripts sourcing this file
CHECK_ONLY=false
# shellcheck disable=SC2034 # used by distro scripts sourcing this file
METHOD=""
RELEASE_JSON=""
# shellcheck disable=SC2034 # set here, used by distro scripts sourcing this file
LATEST_TAG=""

log() { printf '%s\n' "$*"; }
info() { printf '==> %s\n' "$*"; }
warn() { printf '[warning] %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

confirm() {
  local reply
  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi
  read -r -p "$1 [y/N]: " reply
  [[ "${reply:-}" =~ ^[Yy]$ ]]
}

http_get() {
  local url="$1" out="$2"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 600 \
    -o "$out" "$url"
}

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

normalize_version() {
  local v="${1#v}"
  v="$(printf '%s' "$v" | tr -d '[:space:]')"
  printf '%s' "$v"
}

# Prints 0 (true) if $1 sorts strictly newer than $2 by version.
version_is_newer() {
  local a b top
  a="$(normalize_version "$1")"
  b="$(normalize_version "$2")"
  [[ "$a" == "$b" ]] && return 1
  top="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)"
  [[ "$top" == "$a" ]]
}

# Fetches the latest release JSON into RELEASE_JSON. Returns 1 on any
# failure (rate limit, offline, API change) so callers can degrade
# gracefully instead of blocking.
fetch_latest_release_json() {
  local curl_args=() json
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  json="$(curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
    "${curl_args[@]}" "$OC_API_LATEST" 2>/dev/null)" || return 1
  [[ -n "$json" ]] || return 1
  RELEASE_JSON="$json"
  return 0
}

latest_tag_from_json() {
  local tag
  tag="$(printf '%s' "$RELEASE_JSON" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1)"
  [[ -n "$tag" ]] || return 1
  printf '%s' "$tag"
}

# Emits "name<TAB>url" pairs for every release asset. The JSON is flattened
# and clipped to everything after the root-level "assets" marker (dropping
# the release's own name), then each "browser_download_url" is paired with
# the nearest preceding "name". This survives pretty-printing, nested
# uploader objects, and values containing brackets (e.g. "agent[bot]").
asset_pairs_from_json() {
  local assets
  assets="$(printf '%s' "$RELEASE_JSON" | tr -d '\n')"
  assets="${assets#*\"assets\"*\[}"
  printf '%s' "$assets" |
    grep -oE '"(name|browser_download_url)"[[:space:]]*:[[:space:]]*"[^"]*"' |
    awk -F'"' '$2 == "name" { last = $4 } $2 == "browser_download_url" { print last "\t" $4 }'
}

# If the release publishes a checksum asset covering any of the given file
# names, print the expected sha256 and return 0; otherwise return 1.
published_checksum_for() {
  local asset_name asset_url tmp sum fname candidate line
  local -a sum_lines=()
  while IFS=$'\t' read -r asset_name asset_url; do
    [[ -n "${asset_name:-}" ]] || continue
    case "$(printf '%s' "$asset_name" | tr '[:upper:]' '[:lower:]')" in
    *sha256sum* | *checksums* | *.sha256) ;;
    *) continue ;;
    esac
    tmp="$(mktemp)"
    if http_get "$asset_url" "$tmp"; then
      mapfile -t sum_lines <"$tmp"
    fi
    rm -f "$tmp"
    local line sum fname candidate
    for line in "${sum_lines[@]}"; do
      # shellcheck disable=SC2034 # extra is intentionally discarded
      read -r sum fname extra <<<"$line"
      for candidate in "$@"; do
        if [[ "$fname" == "$candidate" ]] &&
          [[ "$(printf '%s' "$sum" | tr '[:upper:]' '[:lower:]')" =~ ^[0-9a-f]{64}$ ]]; then
          printf '%s' "$sum"
          return 0
        fi
      done
    done
  done < <(asset_pairs_from_json)
  return 1
}

# Downloads the official installer into $1/<name>, verifies integrity and
# prints the path of the verified file. Aborts on any doubt (fail closed).
acquire_verified_installer() {
  local dir="$1" mirror f_main f_mirror h_main h_mirror published
  f_main="${dir}/opencode-install.sh"
  f_mirror="${dir}/opencode-install.mirror.sh"

  # Progress messages go to stderr: this function's stdout is captured
  # by callers and must contain only the verified file path.
  info "Downloading official installer to a temp file (not piping it to bash)" >&2
  http_get "$OC_INSTALLER_URL" "$f_main" ||
    die "could not download ${OC_INSTALLER_URL}"
  [[ -s "$f_main" ]] || die "downloaded installer is empty"

  h_main="$(sha256_of "$f_main")"

  published="$(published_checksum_for "install" "opencode-install.sh" || true)"
  if [[ -n "$published" ]]; then
    info "Release publishes a checksum; verifying strictly" >&2
    if [[ "$(printf '%s' "$h_main" | tr '[:upper:]' '[:lower:]')" != "$published" ]]; then
      die "checksum mismatch for the installer (expected ${published}, got ${h_main}). Aborting."
    fi
    printf '%s\n' "$f_main"
    return 0
  fi

  info "Upstream publishes no checksum; cross-checking a second official source" >&2
  mirror="$OC_INSTALLER_MIRROR"
  http_get "$mirror" "$f_mirror" ||
    die "fail closed: could not fetch verification copy from ${mirror}. Refusing to execute an unverified script."
  [[ -s "$f_mirror" ]] || die "verification copy from ${mirror} is empty. Aborting."
  h_mirror="$(sha256_of "$f_mirror")"
  if [[ "$h_main" != "$h_mirror" ]]; then
    die "integrity check FAILED: installer differs between opencode.ai (${h_main}) and ${mirror} (${h_mirror}). Aborting."
  fi

  printf '%s\n' "$f_main"
}

# Resolves how opencode was installed: "installer", "npm", "none".
detect_channel() {
  local resolved
  if ! command -v opencode >/dev/null 2>&1; then
    printf 'none'
    return 0
  fi
  resolved="$(readlink -f "$(command -v opencode)")"
  case "$resolved" in
  "${HOME}/.opencode/"*) printf 'installer' ;;
  */node_modules/*) printf 'npm' ;;
  *) printf 'unknown' ;;
  esac
}

installed_version() {
  command -v opencode >/dev/null 2>&1 || return 0
  opencode --version 2>/dev/null |
    grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
  return 0
}

# Adds ~/.opencode/bin to PATH in a shell rc file, idempotently.
ensure_path_entry() {
  local rc="$1"
  # shellcheck disable=SC2016 # the literal $HOME must reach the rc file
  local line='export PATH="$HOME/.opencode/bin:$PATH"'
  if [[ -f "$rc" ]] && grep -qF '.opencode/bin' "$rc"; then
    return 0
  fi
  {
    printf '\n# Added by bootstrap install-opencode script\n'
    printf '%s\n' "$line"
  } >>"$rc"
  log "Added opencode to PATH in ${rc}"
}
