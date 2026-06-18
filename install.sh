#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_URL="${SCRIPT_URL:-https://github.com/kuss0/caddy.sh/raw/main/caddy.sh}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/caddy.sh}"
RUN_INIT="true"

green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
none='\033[0m'

log() { printf "${green}[INFO]${none} %s\n" "$*"; }
warn() { printf "${yellow}[WARN]${none} %s\n" "$*" >&2; }
fail() { printf "${red}[ERROR]${none} %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  bash install.sh [--no-init]

Environment:
  SCRIPT_URL     Source URL for caddy.sh
  INSTALL_PATH   Install path, default: /usr/local/bin/caddy.sh
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --no-init)
      RUN_INIT="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

log "caddy.sh installer"

[[ "${EUID}" -eq 0 ]] || fail "Run as root, for example: bash <(wget -qO- https://github.com/kuss0/caddy.sh/raw/main/install.sh)"
command -v bash >/dev/null 2>&1 || fail "Missing bash."
command -v install >/dev/null 2>&1 || fail "Missing install command."

download_file() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "${dest}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=3 --timeout=15 -O "${dest}" "${url}"
  else
    fail "Missing curl or wget."
  fi
}

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT INT TERM

log "Downloading caddy.sh from ${SCRIPT_URL}"
download_file "${SCRIPT_URL}" "${tmp}" || fail "Failed to download caddy.sh."
bash -n "${tmp}" || fail "Downloaded caddy.sh failed syntax validation."

install -m 0755 -o root -g root "${tmp}" "${INSTALL_PATH}"
log "Installed ${INSTALL_PATH}"

if [[ "${RUN_INIT}" == "true" ]]; then
  if [[ -r /dev/tty ]]; then
    log "Starting init. You will be asked for the Cloudflare API Token."
    "${INSTALL_PATH}" init < /dev/tty
  else
    warn "No TTY available; installed script but skipped init."
    warn "Run later: ${INSTALL_PATH} init"
  fi
else
  log "Skipped init. Run: ${INSTALL_PATH} init"
fi
