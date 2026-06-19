#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_URL="${SCRIPT_URL:-https://github.com/kuss0/caddy.sh/raw/main/caddy.sh}"
INSTALLER_URL="${INSTALLER_URL:-https://github.com/kuss0/caddy.sh/raw/main/install.sh}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/caddy.sh}"
SHORTCUT_PATH="${SHORTCUT_PATH:-/usr/local/bin/c}"
RUN_MODE="menu"
ORIGINAL_ARGS=("$@")

green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
none='\033[0m'

log() { printf "${green}[INFO]${none} %s\n" "$*"; }
warn() { printf "${yellow}[WARN]${none} %s\n" "$*" >&2; }
fail() { printf "${red}[ERROR]${none} %s\n" "$*" >&2; exit 1; }

have_tty() {
  [[ -e /dev/tty ]] || return 1
  { : < /dev/tty; } 2>/dev/null
}

usage() {
  cat <<EOF
Usage:
  bash install.sh [--menu|--init|--no-init]

Environment:
  SCRIPT_URL     Source URL for caddy.sh
  INSTALLER_URL  Source URL for this installer
  INSTALL_PATH   Install path, default: /usr/local/bin/caddy.sh
  SHORTCUT_PATH  Shortcut path, default: /usr/local/bin/c
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --no-init)
      RUN_MODE="none"
      shift
      ;;
    --menu)
      RUN_MODE="menu"
      shift
      ;;
    --init)
      RUN_MODE="init"
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

command -v bash >/dev/null 2>&1 || fail "Missing bash."

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

rerun_as_root() {
  local status tmp
  command -v sudo >/dev/null 2>&1 || fail "Run as root or install sudo."
  tmp="$(mktemp)"
  log "Downloading installer for sudo re-run from ${INSTALLER_URL}"
  if ! download_file "${INSTALLER_URL}" "${tmp}"; then
    rm -f "${tmp}"
    fail "Failed to download installer for sudo re-run."
  fi
  log "Re-running installer with sudo."
  sudo env \
    SCRIPT_URL="${SCRIPT_URL}" \
    INSTALLER_URL="${INSTALLER_URL}" \
    INSTALL_PATH="${INSTALL_PATH}" \
    SHORTCUT_PATH="${SHORTCUT_PATH}" \
    CADDY_VERSION="${CADDY_VERSION:-}" \
    bash "${tmp}" "$@"
  status=$?
  rm -f "${tmp}"
  exit "${status}"
}

if [[ "${EUID}" -ne 0 ]]; then
  rerun_as_root "${ORIGINAL_ARGS[@]}"
fi

command -v install >/dev/null 2>&1 || fail "Missing install command."
command -v ln >/dev/null 2>&1 || fail "Missing ln command."
command -v readlink >/dev/null 2>&1 || fail "Missing readlink command."

install_shortcut() {
  local existing="" target
  target="$(readlink -f "${INSTALL_PATH}")"
  if [[ -e "${SHORTCUT_PATH}" || -L "${SHORTCUT_PATH}" ]]; then
    existing="$(readlink -f "${SHORTCUT_PATH}" 2>/dev/null || true)"
    if [[ "${existing}" != "${target}" ]]; then
      warn "${SHORTCUT_PATH} already exists and does not point to ${target}; skipped shortcut."
      return 0
    fi
  fi
  ln -sf "${target}" "${SHORTCUT_PATH}"
  chmod 0755 "${SHORTCUT_PATH}" 2>/dev/null || true
  log "Shortcut installed: ${SHORTCUT_PATH}"
}

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT INT TERM

log "Downloading caddy.sh from ${SCRIPT_URL}"
download_file "${SCRIPT_URL}" "${tmp}" || fail "Failed to download caddy.sh."
bash -n "${tmp}" || fail "Downloaded caddy.sh failed syntax validation."

install -m 0755 -o root -g root "${tmp}" "${INSTALL_PATH}"
log "Installed ${INSTALL_PATH}"
install_shortcut

case "${RUN_MODE}" in
  menu)
    if have_tty; then
      log "Opening caddy.sh menu."
      "${INSTALL_PATH}" menu < /dev/tty
    else
      warn "No TTY available; installed script but skipped menu."
      warn "Run later: ${SHORTCUT_PATH}"
    fi
    ;;
  init)
    if have_tty; then
      log "Starting init. You will be asked for the Cloudflare API Token."
      "${INSTALL_PATH}" init < /dev/tty
    else
      warn "No TTY available; installed script but skipped init."
      warn "Run later: ${INSTALL_PATH} init"
    fi
    ;;
  none)
    log "Skipped menu/init. Run: ${SHORTCUT_PATH}"
    ;;
esac
