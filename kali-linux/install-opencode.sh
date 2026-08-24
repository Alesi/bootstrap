#!/usr/bin/env bash
#
# install-opencode.sh — install/update opencode (https://opencode.ai) on Kali Linux.
#
# Design notes (issue #8):
# - Re-runnable: detects an existing install, its channel and its version.
#   A fresh install defaults to the official installer; an existing install
#   stays on the channel it came from (never silently switches managers);
#   an explicit --method change asks for confirmation first.
# - Update flow: compares the installed version against the latest GitHub
#   release and prompts [y/N] before upgrading. Handles v-prefixed tags.
# - Channels:
#     installer (default) — official https://opencode.ai/install script,
#         downloaded to a temp file, integrity-checked, THEN executed.
#         Never piped straight into bash.
#     npm                 — npm package "opencode-ai"; the registry enforces
#         sha512 integrity itself. Needs nodejs+npm.
# - Integrity, honest scope: downloads go over TLS to pinned official
#   domains. If upstream publishes checksums for a downloaded file they are
#   enforced strictly (fail closed); otherwise the installer is cross-checked
#   against a second independent official source (raw.githubusercontent.com
#   of anomalyco/opencode) and must match byte-for-byte. These checks prove
#   transport integrity and cross-source consistency — they cannot rule out
#   compromise of upstream itself. No download-based install can.
# - No root required: everything lands in your home directory. The npm
#   channel needs nodejs/npm, which you install with apt yourself.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved at runtime, linted separately
source "${SCRIPT_DIR}/../lib/install-opencode-common.sh"

TMP_DIR=""
cleanup() {
  [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: install-opencode.sh [options]

Install or update opencode (https://opencode.ai) on Kali Linux.
Safe to re-run: detects existing installs and offers updates.

Options:
    -h, --help          Show this help and exit.
    -y, --yes           Assume "yes" for all prompts (non-interactive).
    --method CHANNEL    Force a channel: "installer" (default) or "npm".
    --check-only        Report installed/latest versions and exit.
                        Exit codes: 0 up to date, 1 update available,
                        2 could not determine.

Channels:
    installer   Official installer from opencode.ai, downloaded to a temp
                file and integrity-checked before it is executed.
    npm         Global npm package "opencode-ai" (requires nodejs/npm).

Environment:
    GITHUB_TOKEN                    Optional; raises GitHub API rate limits.
    BOOTSTRAP_SKIP_DISTRO_CHECK=1   Skip the distro check (for testing).
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -y | --yes)
      # shellcheck disable=SC2034 # consumed by the shared lib
      ASSUME_YES="true"
      ;;
    --method)
      [[ $# -ge 2 ]] || die "--method requires a value (installer|npm)"
      METHOD="$2"
      shift
      ;;
    --method=*)
      METHOD="${1#*=}"
      ;;
    --check-only)
      CHECK_ONLY="true"
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
    esac
    shift
  done
  case "$METHOD" in
  "" | installer | npm) ;;
  *)
    die "invalid --method '$METHOD' (expected: installer or npm)"
    ;;
  esac
}

assert_supported_distro() {
  [[ "${BOOTSTRAP_SKIP_DISTRO_CHECK:-0}" == "1" ]] && return 0
  if [[ ! -r /etc/os-release ]] ||
    ! grep -Eq '^(ID|ID_LIKE)=.*\b(kali|debian)\b' /etc/os-release; then
    die "this script currently supports Kali Linux (Debian family) only."
  fi
}

# Sets METHOD from the detected channel unless the user forced one;
# asks for confirmation before switching channels on an existing install.
resolve_method() {
  local detected="$1" desired
  case "$detected" in
  npm) desired="npm" ;;
  *) desired="installer" ;;
  esac
  if [[ -z "$METHOD" ]]; then
    METHOD="$desired"
    return 0
  fi
  if [[ "$detected" != "none" && "$METHOD" != "$desired" ]]; then
    warn "Existing opencode install uses the '${detected}' channel, but --method '${METHOD}' was requested."
    warn "Letting two channels own the same 'opencode' command breaks updates later."
    if [[ "$detected" == "npm" ]]; then
      warn "Consider removing the old one first: sudo npm uninstall -g ${OC_NPM_PACKAGE}"
    else
      warn "Consider removing the old one first: rm -rf ${HOME}/.opencode"
    fi
    confirm "Continue with '${METHOD}' anyway?" ||
      die "aborted; nothing was changed."
  fi
}

# Sets LATEST_TAG/LATEST_VERSION; returns 1 (and warns) when the GitHub API
# cannot be reached or is rate-limited. Never blocks an install.
refresh_latest() {
  LATEST_TAG=""
  LATEST_VERSION=""
  # shellcheck disable=SC2034 # consumed by fetch_latest_release_json
  RELEASE_JSON=""
  if fetch_latest_release_json && LATEST_TAG="$(latest_tag_from_json)"; then
    LATEST_VERSION="$(normalize_version "$LATEST_TAG")"
    return 0
  fi
  warn "Could not determine the latest version (GitHub API unreachable or rate-limited); skipping the update comparison."
  return 1
}

require_npm_prereqs() {
  if ! command -v npm >/dev/null 2>&1; then
    die "the npm channel needs nodejs/npm, which are not installed.
Install them first, then re-run this script:
    sudo apt update && sudo apt install -y nodejs npm"
  fi
}

do_install_installer() {
  local verified
  TMP_DIR="$(mktemp -d)"
  verified="$(acquire_verified_installer "$TMP_DIR")"
  info "Installer sha256: $(sha256_of "$verified")"
  info "Source: ${OC_INSTALLER_URL} (cross-checked against github.com/${OC_REPO})"
  confirm "Execute the verified installer now?" ||
    die "aborted; nothing was executed."
  bash "$verified" --no-modify-path ||
    die "the official installer failed; see its output above."
}

do_install_npm() {
  require_npm_prereqs
  info "Installing ${OC_NPM_PACKAGE}@latest from the npm registry (integrity enforced by npm itself)"
  npm install -g "${OC_NPM_PACKAGE}@latest" ||
    die "npm installation failed; see npm's output above."
}

run_method_install() {
  local previous_version="$1"
  if [[ "$METHOD" == "npm" ]]; then
    do_install_npm
  else
    do_install_installer
  fi
  verify_result "$previous_version"
}

verify_result() {
  local previous_version="$1" bin="" got=""
  if [[ "$METHOD" == "installer" ]]; then
    bin="${OC_BIN_DIR}/opencode"
  else
    bin="$(command -v opencode)"
  fi
  if [[ -z "${bin:-}" ]] || [[ ! -x "$bin" ]]; then
    die "an 'opencode' executable was not found after installation."
  fi
  got="$(normalize_version "$("$bin" --version 2>/dev/null | grep -m 1 -oE '[0-9]+(\.[0-9]+)+' || true)")"
  if [[ -z "$got" ]]; then
    die "'${bin} --version' produced no usable version string."
  fi
  if [[ -n "$previous_version" ]] &&
    ! version_is_newer "$got" "$previous_version"; then
    warn "Version did not advance (${previous_version} -> ${got}); the channel may be lagging upstream."
  else
    info "opencode ${got} is ready at ${bin}"
  fi
}

finish_up() {
  if [[ "$METHOD" == "installer" ]]; then
    ensure_path_entry "${HOME}/.bashrc"
    [[ -f "${HOME}/.zshrc" ]] && ensure_path_entry "${HOME}/.zshrc"
    log
    log "Open a new terminal or run: source ~/.bashrc"
  fi
  log
  log "Note: integrity checks passed, but they cannot guarantee the absence"
  log "of malware in upstream releases themselves. Verify odd behavior"
  log "against https://github.com/${OC_REPO} before trusting the binary."
}

run_check_only() {
  local detected="$1" current="$2"
  info "installed: ${current:-<none>} (channel: ${detected})"
  refresh_latest || exit 2
  info "latest: ${LATEST_TAG}"
  if [[ -z "$current" ]]; then
    log "status: not installed (run without --check-only to install)"
    exit 1
  fi
  if version_is_newer "$LATEST_VERSION" "$current"; then
    log "status: update available (${current} -> ${LATEST_VERSION})"
    exit 1
  fi
  log "status: up to date"
  exit 0
}

main() {
  parse_args "$@"
  assert_supported_distro
  if [[ "$EUID" -eq 0 ]]; then
    warn "Running as root: opencode will be installed for root, not for your user."
  fi

  local detected current
  detected="$(detect_channel)"
  current="$(installed_version)"

  if [[ "$CHECK_ONLY" == "true" ]]; then
    run_check_only "$detected" "$current"
  fi

  resolve_method "$detected"

  local latest_ok="false"
  if refresh_latest; then
    latest_ok="true"
  fi

  if [[ -z "$current" ]]; then
    info "opencode is not installed; installing latest ${LATEST_TAG:+(${LATEST_TAG}) }via the '${METHOD}' channel"
  else
    info "Detected opencode ${current} (channel: ${detected})"
  fi

  if [[ -n "$current" ]]; then
    update_existing "$latest_ok" "$current"
  else
    run_method_install ""
    finish_up
  fi
}

update_existing() {
  local latest_ok="$1" current="$2"
  if [[ "$latest_ok" != "true" ]]; then
    info "Nothing to compare against right now; re-run this script later to update."
    return 0
  fi
  if ! version_is_newer "$LATEST_VERSION" "$current"; then
    info "opencode ${current} is up to date (latest release: ${LATEST_TAG})."
    return 0
  fi
  info "Update available: ${current} -> ${LATEST_VERSION}"
  if ! confirm "Upgrade now?"; then
    log "Upgrade skipped."
    return 0
  fi
  run_method_install "$current"
  finish_up
}

main "$@"
