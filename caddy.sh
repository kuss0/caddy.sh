#!/usr/bin/env bash
set -Eeuo pipefail

CADDY_BIN="/usr/local/bin/caddy"
CADDY_VERSION="${CADDY_VERSION:-v2.11.4}"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/kuss0/caddy.sh/main/caddy.sh}"
CADDY_CONFIG="/etc/caddy"
CADDYFILE="${CADDY_CONFIG}/Caddyfile"
SITES_DIR="${CADDY_CONFIG}/conf.d"
DISABLED_DIR="${CADDY_CONFIG}/disabled"
ENV_FILE="${CADDY_CONFIG}/caddy.env"
SERVICE_FILE="/etc/systemd/system/caddy.service"
CADDY_DATA="/var/lib/caddy"
CADDY_USER="caddy"
CADDY_GROUP="caddy"
MANAGED_MARKER="# managed-by: caddy-cloudflare-deploy"

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  $0 init [--force]                Install/init Caddy and save Cloudflare token once
  $0 set-token                     Update Cloudflare token
  $0 add DOMAIN LOCAL_PORT         Add or update one reverse proxy site
  $0 remove DOMAIN                 Disable one site
  $0 list                          List enabled sites
  $0 reload                        Validate and reload Caddy
  $0 self-update                   Update this script from GitHub
  $0 upgrade-caddy [VERSION]       Upgrade Caddy binary, for example v2.11.4
  $0 uninstall [--purge]           Uninstall Caddy; --purge also removes config/data

Examples:
  CADDY_VERSION=v2.11.4 $0 init
  $0 self-update
  $0 upgrade-caddy v2.11.4
  $0 uninstall
  $0 init
  $0 add nezha.example.eu.org 8008
  $0 add cert.example.eu.org 8090
  $0 remove nezha.example.eu.org
EOF
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Run this script as root."
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

validate_token() {
  local token="$1"
  [[ -n "${token}" ]] || fail "Cloudflare token is empty."
  [[ "${token}" != *$'\n'* ]] || fail "Cloudflare token must not contain newlines."
  [[ "${token}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Cloudflare token contains unexpected characters."
}

validate_caddy_version() {
  [[ "${CADDY_VERSION}" =~ ^v[0-9]+(\.[0-9]+){2}([-+][A-Za-z0-9._-]+)?$ ]] || fail "Invalid CADDY_VERSION: ${CADDY_VERSION}"
}

download_file() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "${dest}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${dest}" "${url}"
  else
    fail "Missing curl or wget."
  fi
}

read_token() {
  local token
  printf 'Cloudflare API Token: ' >&2
  read -r -s token
  printf '\n' >&2
  validate_token "${token}"
  printf '%s' "${token}"
}

read_env_value() {
  local key="$1" file="$2" line value
  [[ -f "${file}" ]] || fail "Missing ${file}. Run: $0 init"
  line="$(grep -m1 -E "^${key}=" "${file}" || true)"
  [[ -n "${line}" ]] || fail "Missing ${key} in ${file}."
  value="${line#*=}"
  if [[ "${value}" == \'*\' ]]; then
    value="${value#\'}"
    value="${value%\'}"
  fi
  printf '%s' "${value}"
}

validate_domain() {
  local domain="$1" name label
  [[ -n "${domain}" ]] || fail "Domain is empty."
  [[ "${domain}" =~ ^(\*\.)?[A-Za-z0-9.-]+$ ]] || fail "Invalid domain: ${domain}"
  [[ "${domain}" != *..* ]] || fail "Invalid domain: ${domain}"
  if [[ "${domain}" == \*.* ]]; then
    name="${domain#\*.}"
  else
    name="${domain}"
  fi
  [[ ${#name} -le 253 ]] || fail "Invalid domain: ${domain}"

  IFS='.' read -r -a labels <<< "${name}"
  ((${#labels[@]} >= 2)) || fail "Domain must contain at least two labels: ${domain}"
  for label in "${labels[@]}"; do
    label="${label,,}"
    [[ -n "${label}" && ${#label} -le 63 ]] || fail "Invalid domain label in ${domain}"
    [[ "${label}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail "Invalid domain label in ${domain}"
  done
}

validate_port() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] || fail "Port must be a number."
  (( port >= 1 && port <= 65535 )) || fail "Port must be between 1 and 65535."
}

site_file_for_domain() {
  local domain="$1"
  validate_domain "${domain}"
  local safe="${domain//\*/_wildcard_}"
  printf '%s/%s.caddy' "${SITES_DIR}" "${safe}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l) printf 'armv7' ;;
    *) fail "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

download_caddy() {
  local arch tmp url
  validate_caddy_version
  arch="$(detect_arch)"
  tmp="$(mktemp)"
  url="https://caddyserver.com/api/download?os=linux&arch=${arch}&p=github.com/caddy-dns/cloudflare&version=${CADDY_VERSION}"

  log "Downloading Caddy ${CADDY_VERSION} with Cloudflare DNS plugin for linux/${arch}."
  if ! download_file "${url}" "${tmp}"; then
    rm -f "${tmp}"
    fail "Failed to download Caddy."
  fi

  if ! chmod 0755 "${tmp}"; then
    rm -f "${tmp}"
    fail "Failed to mark downloaded Caddy binary executable."
  fi
  if ! "${tmp}" version >/dev/null; then
    rm -f "${tmp}"
    fail "Downloaded file is not a valid Caddy binary."
  fi
  if ! "${tmp}" version | grep -Fq "${CADDY_VERSION#v}"; then
    rm -f "${tmp}"
    fail "Downloaded Caddy version does not match ${CADDY_VERSION}."
  fi
  if ! "${tmp}" list-modules | grep -Fq "dns.providers.cloudflare"; then
    rm -f "${tmp}"
    fail "Downloaded Caddy lacks the Cloudflare DNS plugin."
  fi
  if ! install -m 0755 "${tmp}" "${CADDY_BIN}"; then
    rm -f "${tmp}"
    fail "Failed to install Caddy binary."
  fi
  rm -f "${tmp}"
  log "Installed $(${CADDY_BIN} version)."
}

ensure_caddy_binary() {
  if [[ -x "${CADDY_BIN}" ]] && "${CADDY_BIN}" list-modules 2>/dev/null | grep -Fq "dns.providers.cloudflare"; then
    log "Existing Caddy already has the Cloudflare DNS plugin."
    return
  fi

  [[ ! -x "${CADDY_BIN}" ]] || warn "Existing Caddy lacks the Cloudflare DNS plugin. Replacing it."
  download_caddy
}

ensure_user_and_dirs() {
  getent group "${CADDY_GROUP}" >/dev/null || groupadd --system "${CADDY_GROUP}"
  id -u "${CADDY_USER}" >/dev/null 2>&1 || useradd --system \
    --gid "${CADDY_GROUP}" \
    --home-dir "${CADDY_DATA}" \
    --shell /usr/sbin/nologin \
    "${CADDY_USER}"

  install -d -m 0755 -o root -g root "${CADDY_CONFIG}" "${SITES_DIR}" "${DISABLED_DIR}"
  install -d -m 0750 -o "${CADDY_USER}" -g "${CADDY_GROUP}" "${CADDY_DATA}" "${CADDY_DATA}/.config"
  touch "${SITES_DIR}/00-empty.caddy"
  chmod 0644 "${SITES_DIR}/00-empty.caddy"
}

write_env_file() {
  local token="$1"
  validate_token "${token}"
  umask 077
  {
    printf 'CF_API_TOKEN=%s\n' "${token}"
    printf 'XDG_DATA_HOME=%s\n' "${CADDY_DATA}"
    printf 'XDG_CONFIG_HOME=%s\n' "${CADDY_DATA}/.config"
  } > "${ENV_FILE}"
  chown root:"${CADDY_GROUP}" "${ENV_FILE}"
  chmod 0640 "${ENV_FILE}"
}

service_is_managed() {
  [[ -f "${SERVICE_FILE}" ]] || return 1
  grep -Fq "${MANAGED_MARKER}" "${SERVICE_FILE}" && return 0
  grep -Fq "ExecStart=${CADDY_BIN} run --config ${CADDYFILE}" "${SERVICE_FILE}"
}

write_service() {
  local force="${1:-false}" backup
  if [[ -f "${SERVICE_FILE}" ]]; then
    if [[ "${force}" != "true" ]] && ! service_is_managed; then
      fail "Existing ${SERVICE_FILE} is unmanaged. Re-run init with --force to back it up and replace it."
    fi
    backup="${SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${SERVICE_FILE}" "${backup}"
    log "Backed up existing service to ${backup}."
  fi

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
# ${MANAGED_MARKER#\# }
Type=notify
User=${CADDY_USER}
Group=${CADDY_GROUP}
EnvironmentFile=${ENV_FILE}
ExecStart=${CADDY_BIN} run --config ${CADDYFILE}
ExecReload=${CADDY_BIN} reload --config ${CADDYFILE} --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${CADDY_DATA}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "${SERVICE_FILE}"
  chmod 0644 "${SERVICE_FILE}"
}

write_base_caddyfile() {
  local force="${1:-false}"
  if [[ -f "${CADDYFILE}" && "${force}" != "true" ]]; then
    if grep -Fq "${MANAGED_MARKER}" "${CADDYFILE}"; then
      log "Existing Caddyfile already imports ${SITES_DIR}/*.caddy."
      return
    fi
    fail "Existing ${CADDYFILE} is unmanaged. Re-run init with --force to back it up and replace it."
  fi

  if [[ -f "${CADDYFILE}" ]]; then
    cp -a "${CADDYFILE}" "${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "${CADDYFILE}" <<EOF
${MANAGED_MARKER}
# Site configs live in ${SITES_DIR}.

(CF_CERT) {
    tls {
        dns cloudflare {\$CF_API_TOKEN}
    }
}

import ${SITES_DIR}/*.caddy
EOF
  chown root:root "${CADDYFILE}"
  chmod 0644 "${CADDYFILE}"
}

load_env_file() {
  CF_API_TOKEN="$(read_env_value CF_API_TOKEN "${ENV_FILE}")"
  XDG_DATA_HOME="$(read_env_value XDG_DATA_HOME "${ENV_FILE}")"
  XDG_CONFIG_HOME="$(read_env_value XDG_CONFIG_HOME "${ENV_FILE}")"
  export CF_API_TOKEN XDG_DATA_HOME XDG_CONFIG_HOME
}

validate_config() {
  load_env_file
  "${CADDY_BIN}" validate --config "${CADDYFILE}" || {
    warn "Caddyfile validation failed."
    return 1
  }
}

reload_caddy() {
  validate_config || return 1
  systemctl daemon-reload || return 1
  systemctl enable caddy >/dev/null || return 1

  if systemctl is-active --quiet caddy; then
    systemctl reload caddy || systemctl restart caddy || return 1
  else
    systemctl start caddy || return 1
  fi

  systemctl --no-pager --full status caddy >/dev/null || {
    journalctl -u caddy -n 80 --no-pager >&2 || true
    warn "Caddy is not healthy."
    return 1
  }
}

resolve_self_path() {
  if [[ "${0}" == */* ]]; then
    readlink -f "${0}"
  else
    command -v "${0}"
  fi
}

check_ports() {
  local occupied
  occupied="$(ss -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null | sed '1d' | grep -Fv 'users:(("caddy",' || true)"
  if [[ -n "${occupied}" ]]; then
    warn "Port 80 or 443 is already in use by a non-Caddy process:"
    printf '%s\n' "${occupied}" >&2
    fail "Release port 80/443 before initializing Caddy."
  fi
}

cmd_init() {
  local force="false"
  if [[ "${1:-}" == "--force" ]]; then
    force="true"
    shift
  fi
  [[ "$#" -eq 0 ]] || fail "Unexpected arguments for init."
  if [[ -f "${CADDYFILE}" && "${force}" != "true" ]] && ! grep -Fq "${MANAGED_MARKER}" "${CADDYFILE}"; then
    fail "Existing ${CADDYFILE} is unmanaged. Re-run init with --force to back it up and replace it."
  fi

  ensure_caddy_binary
  ensure_user_and_dirs

  if [[ ! -f "${ENV_FILE}" ]]; then
    write_env_file "$(read_token)"
  else
    log "Keeping existing Cloudflare token in ${ENV_FILE}."
  fi

  check_ports
  write_service "${force}"
  write_base_caddyfile "${force}"
  reload_caddy || fail "Caddy failed to initialize."
  log "Initialized Caddy. Add sites with: $0 add DOMAIN LOCAL_PORT"
}

cmd_self_update() {
  local target tmp backup
  [[ "$#" -eq 0 ]] || fail "Usage: $0 self-update"
  target="$(resolve_self_path)"
  [[ -n "${target}" ]] || fail "Unable to resolve script path."
  [[ -f "${target}" ]] || fail "Script path is not a regular file: ${target}"

  tmp="$(mktemp)"
  if ! download_file "${SCRIPT_URL}" "${tmp}"; then
    rm -f "${tmp}"
    fail "Failed to download script update."
  fi
  if ! bash -n "${tmp}"; then
    rm -f "${tmp}"
    fail "Downloaded script failed syntax validation."
  fi

  backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "${target}" "${backup}"
  install -m 0755 -o root -g root "${tmp}" "${target}"
  rm -f "${tmp}"
  log "Updated script at ${target}."
  log "Backup saved at ${backup}."
}

cmd_upgrade_caddy() {
  local backup=""
  [[ "$#" -le 1 ]] || fail "Usage: $0 upgrade-caddy [VERSION]"
  if [[ -n "${1:-}" ]]; then
    CADDY_VERSION="$1"
  fi
  validate_caddy_version

  if [[ -x "${CADDY_BIN}" ]]; then
    backup="${CADDY_BIN}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${CADDY_BIN}" "${backup}"
    log "Backed up existing Caddy binary to ${backup}."
  fi

  download_caddy
  if [[ -f "${CADDYFILE}" && -f "${ENV_FILE}" ]]; then
    if ! reload_caddy; then
      warn "Caddy reload failed after upgrade."
      if [[ -n "${backup}" && -f "${backup}" ]]; then
        warn "Rolling back Caddy binary from ${backup}."
        cp -a "${backup}" "${CADDY_BIN}"
        reload_caddy || true
      fi
      fail "Caddy upgrade failed; rolled back when possible."
    fi
  else
    log "Caddy binary upgraded. Service is not initialized yet, so reload was skipped."
  fi
}

cmd_uninstall() {
  local purge="false"
  if [[ "${1:-}" == "--purge" ]]; then
    purge="true"
    shift
  fi
  [[ "$#" -eq 0 ]] || fail "Usage: $0 uninstall [--purge]"

  if systemctl list-unit-files caddy.service >/dev/null 2>&1 || [[ -f "${SERVICE_FILE}" ]]; then
    systemctl stop caddy >/dev/null 2>&1 || true
    systemctl disable caddy >/dev/null 2>&1 || true
  fi

  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload || true
  systemctl reset-failed caddy >/dev/null 2>&1 || true

  if [[ -e "${CADDY_BIN}" ]]; then
    rm -f "${CADDY_BIN}"
  fi

  if [[ "${purge}" == "true" ]]; then
    rm -rf "${CADDY_CONFIG}" "${CADDY_DATA}"
    if id -u "${CADDY_USER}" >/dev/null 2>&1; then
      userdel "${CADDY_USER}" 2>/dev/null || warn "Failed to remove user ${CADDY_USER}."
    fi
    if getent group "${CADDY_GROUP}" >/dev/null 2>&1; then
      groupdel "${CADDY_GROUP}" 2>/dev/null || warn "Failed to remove group ${CADDY_GROUP}."
    fi
    log "Caddy uninstalled and purged."
  else
    log "Caddy uninstalled. Config and data were kept at ${CADDY_CONFIG} and ${CADDY_DATA}."
  fi
}

cmd_set_token() {
  local token backup=""
  [[ "$#" -eq 0 ]] || fail "Usage: $0 set-token"
  [[ -f "${CADDYFILE}" ]] || fail "Missing ${CADDYFILE}. Run: $0 init"
  [[ -f "${ENV_FILE}" ]] || fail "Missing ${ENV_FILE}. Run: $0 init"
  token="$(read_token)"
  ensure_user_and_dirs
  if [[ -f "${ENV_FILE}" ]]; then
    backup="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${ENV_FILE}" "${backup}"
  fi
  write_env_file "${token}"
  if ! reload_caddy; then
    warn "Reload failed. Rolling back ${ENV_FILE}."
    if [[ -n "${backup}" && -f "${backup}" ]]; then
      cp -a "${backup}" "${ENV_FILE}"
      reload_caddy || true
    fi
    fail "Failed to update Cloudflare token; rolled back."
  fi
  [[ -z "${backup}" ]] || rm -f "${backup}"
  log "Cloudflare token updated."
}

cmd_add() {
  local domain="${1:-}" port="${2:-}" site_file tmp backup=""
  [[ "$#" -eq 2 ]] || fail "Usage: $0 add DOMAIN LOCAL_PORT"
  validate_domain "${domain}"
  validate_port "${port}"
  [[ -f "${CADDYFILE}" ]] || fail "Missing ${CADDYFILE}. Run: $0 init"
  [[ -f "${ENV_FILE}" ]] || fail "Missing ${ENV_FILE}. Run: $0 init"
  [[ -d "${SITES_DIR}" ]] || fail "Missing ${SITES_DIR}. Run: $0 init"

  site_file="$(site_file_for_domain "${domain}")"
  tmp="$(mktemp)"
  cat > "${tmp}" <<EOF
${domain} {
    import CF_CERT
    reverse_proxy 127.0.0.1:${port}
}
EOF

  if [[ -f "${site_file}" ]]; then
    backup="${site_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${site_file}" "${backup}"
  fi
  install -m 0644 -o root -g root "${tmp}" "${site_file}"
  rm -f "${tmp}"
  if ! reload_caddy; then
    warn "Reload failed. Rolling back ${site_file}."
    if [[ -n "${backup}" && -f "${backup}" ]]; then
      cp -a "${backup}" "${site_file}"
    else
      rm -f "${site_file}"
    fi
    reload_caddy || true
    fail "Failed to enable ${domain}; rolled back."
  fi
  log "Enabled ${domain} -> 127.0.0.1:${port}"
}

cmd_remove() {
  local domain="${1:-}" site_file disabled_file
  [[ "$#" -eq 1 ]] || fail "Usage: $0 remove DOMAIN"
  validate_domain "${domain}"
  site_file="$(site_file_for_domain "${domain}")"
  [[ -f "${site_file}" ]] || fail "No enabled site found for ${domain}."
  install -d -m 0755 -o root -g root "${DISABLED_DIR}"

  disabled_file="${DISABLED_DIR}/$(basename "${site_file}").$(date +%Y%m%d%H%M%S)"
  mv "${site_file}" "${disabled_file}"
  if ! reload_caddy; then
    warn "Reload failed. Restoring ${site_file}."
    mv "${disabled_file}" "${site_file}"
    reload_caddy || true
    fail "Failed to disable ${domain}; restored previous config."
  fi
  log "Disabled ${domain}. Saved previous config at ${disabled_file}"
}

cmd_list() {
  local file domain proxy
  shopt -s nullglob
  for file in "${SITES_DIR}"/*.caddy; do
    [[ "$(basename "${file}")" != "00-empty.caddy" ]] || continue
    domain="$(grep -m1 -E '^[^[:space:]#][^{]*\{' "${file}" | sed -E 's/[[:space:]]*\{[[:space:]]*$//' || true)"
    proxy="$(grep -m1 -E '^[[:space:]]*reverse_proxy[[:space:]]+' "${file}" | sed -E 's/^[[:space:]]*reverse_proxy[[:space:]]+//' || true)"
    printf '%s -> %s\n' "${domain:-$(basename "${file}" .caddy)}" "${proxy:-unknown}"
  done
}

main() {
  need_root
  need_command systemctl
  need_command grep
  need_command sed
  need_command ss

  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || { usage; exit 1; }
  shift || true

  case "${cmd}" in
    init) cmd_init "$@" ;;
    set-token) cmd_set_token "$@" ;;
    add) cmd_add "$@" ;;
    remove|rm|delete) cmd_remove "$@" ;;
    list|ls) cmd_list "$@" ;;
    reload) [[ "$#" -eq 0 ]] || fail "Usage: $0 reload"; reload_caddy || fail "Caddy reload failed." ;;
    self-update|update-script) cmd_self_update "$@" ;;
    upgrade-caddy|update-caddy) cmd_upgrade_caddy "$@" ;;
    uninstall|remove-caddy) cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *) usage; fail "Unknown command: ${cmd}" ;;
  esac
}

main "$@"
