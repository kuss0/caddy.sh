#!/usr/bin/env sh
set -eu

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/kuss0/caddy.sh/main/caddy.sh}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/caddy.sh}"
RUN_INIT="true"

log() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  install.sh [--no-init]

Environment:
  SCRIPT_URL     Source URL for caddy.sh
  INSTALL_PATH   Install path, default: /usr/local/bin/caddy.sh
EOF
}

while [ "$#" -gt 0 ]; do
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

[ "$(id -u)" -eq 0 ] || fail "Run as root, for example: curl -fsSL https://raw.githubusercontent.com/kuss0/caddy.sh/main/install.sh | sudo sh"
command -v bash >/dev/null 2>&1 || fail "Missing bash."

download_file() {
  url="$1"
  dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
  else
    fail "Missing curl or wget."
  fi
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM

log "Downloading caddy.sh from ${SCRIPT_URL}."
download_file "$SCRIPT_URL" "$tmp" || fail "Failed to download caddy.sh."
bash -n "$tmp" || fail "Downloaded caddy.sh failed syntax validation."

install -m 0755 -o root -g root "$tmp" "$INSTALL_PATH"
log "Installed ${INSTALL_PATH}."

if [ "$RUN_INIT" = "true" ]; then
  "$INSTALL_PATH" init
else
  log "Skipped init. Run: ${INSTALL_PATH} init"
fi
