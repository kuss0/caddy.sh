#!/usr/bin/env bash
set -Eeuo pipefail

CADDY_BIN="/usr/local/bin/caddy"
CADDY_VERSION="${CADDY_VERSION:-v2.11.4}"
SCRIPT_URL="${SCRIPT_URL:-https://github.com/kuss0/caddy.sh/raw/main/caddy.sh}"
SHORTCUT_BIN="${SHORTCUT_BIN:-/usr/local/bin/c}"
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

have_tty() {
  [[ -e /dev/tty ]] || return 1
  { : < /dev/tty; } 2>/dev/null
}

usage() {
  cat <<EOF
Usage:
  $0                               Open interactive menu
  $0 menu                          Open interactive menu
  $0 init [--force]                Install/init Caddy and save Cloudflare token once
  $0 set-token                     Update Cloudflare token
  $0 quick                         AI quick connect: scan local services and add a site
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
  $0 quick
  $0 add nezha.example.eu.org 8008
  $0 add cert.example.eu.org 8090
  $0 remove nezha.example.eu.org
EOF
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

run_step() {
  (
    set -Eeuo pipefail
    "$@"
  )
}

ensure_root() {
  local script
  [[ "${EUID}" -eq 0 ]] && return
  command -v sudo >/dev/null 2>&1 || fail "Run as root or install sudo."
  command -v readlink >/dev/null 2>&1 || fail "Missing required command: readlink"
  script="$(resolve_self_path)"
  [[ -n "${script}" && -f "${script}" ]] || fail "Unable to resolve script path for sudo."
  exec sudo env \
    CADDY_ASSUME_YES="${CADDY_ASSUME_YES:-}" \
    CADDY_VERSION="${CADDY_VERSION}" \
    SCRIPT_URL="${SCRIPT_URL}" \
    SHORTCUT_BIN="${SHORTCUT_BIN}" \
    bash "${script}" "$@"
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
    wget --tries=3 --timeout=15 -O "${dest}" "${url}"
  else
    fail "Missing curl or wget."
  fi
}

read_token() {
  local token
  have_tty || fail "No TTY available for secure token input. Run interactively, for example: bash <(wget -O- https://github.com/kuss0/caddy.sh/raw/main/install.sh)"
  printf 'Cloudflare API Token: ' >&2
  read -r -s token < /dev/tty
  printf '\n' >&2
  validate_token "${token}"
  printf '%s' "${token}"
}

tty_read() {
  local prompt="$1"
  have_tty || fail "No TTY available for interactive input."
  printf '%s' "${prompt}" > /dev/tty
  IFS= read -r REPLY < /dev/tty
}

confirm_purge() {
  [[ "${CADDY_ASSUME_YES:-}" == "1" ]] && return
  have_tty || fail "No TTY available for purge confirmation. Set CADDY_ASSUME_YES=1 to purge non-interactively."
  tty_read "Type DELETE to permanently remove ${CADDY_CONFIG} and ${CADDY_DATA}: "
  [[ "${REPLY}" == "DELETE" ]] || fail "Purge cancelled."
}

menu_pause() {
  tty_read "Press Enter to continue..." || true
}

backup_path_state() {
  local path="$1" backup="$2"
  if [[ -e "${path}" || -L "${path}" ]]; then
    cp -a "${path}" "${backup}"
    printf 'present'
  else
    printf 'absent'
  fi
}

restore_path_state() {
  local path="$1" backup="$2" state="$3"
  if [[ "${state}" == "present" ]]; then
    install -d -m 0755 "${path%/*}"
    cp -a "${backup}" "${path}"
  else
    rm -f "${path}"
  fi
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

  log "Downloading Caddy ${CADDY_VERSION} with Cloudflare DNS plugin for linux/${arch}. This can take a minute."
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

install_shortcut() {
  local existing target
  target="$(resolve_self_path)"
  [[ -n "${target}" && -f "${target}" ]] || return 0
  target="$(readlink -f "${target}")"
  if [[ -e "${SHORTCUT_BIN}" || -L "${SHORTCUT_BIN}" ]]; then
    existing="$(readlink -f "${SHORTCUT_BIN}" 2>/dev/null || true)"
    if [[ "${existing}" != "${target}" ]]; then
      warn "${SHORTCUT_BIN} already exists and does not point to ${target}; skipping shortcut."
      return 0
    fi
  fi
  ln -sf "${target}" "${SHORTCUT_BIN}"
  chmod 0755 "${SHORTCUT_BIN}" 2>/dev/null || true
  log "Shortcut installed: ${SHORTCUT_BIN}"
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

cmd_reload() {
  [[ "$#" -eq 0 ]] || fail "Usage: $0 reload"
  reload_caddy || fail "Caddy reload failed."
  log "Caddy reloaded."
}

resolve_self_path() {
  local path source
  source="${BASH_SOURCE[0]}"
  if [[ -f "${source}" ]]; then
    readlink -f "${source}"
  elif [[ "${source}" == */* ]]; then
    readlink -f "${source}"
  else
    path="$(command -v "${source}" 2>/dev/null || true)"
    if [[ -z "${path}" ]]; then
      path="$(command -v "${0}" 2>/dev/null || true)"
    fi
    [[ -n "${path}" ]] || return 1
    readlink -f "${path}"
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
  local caddyfile_state env_state force="false" init_status=0 service_state tmpdir token=""
  if [[ "${1:-}" == "--force" ]]; then
    force="true"
    shift
  fi
  [[ "$#" -eq 0 ]] || fail "Unexpected arguments for init."
  if [[ -f "${CADDYFILE}" && "${force}" != "true" ]] && ! grep -Fq "${MANAGED_MARKER}" "${CADDYFILE}"; then
    fail "Existing ${CADDYFILE} is unmanaged. Re-run init with --force to back it up and replace it."
  fi
  if [[ -f "${SERVICE_FILE}" && "${force}" != "true" ]] && ! service_is_managed; then
    fail "Existing ${SERVICE_FILE} is unmanaged. Re-run init with --force to back it up and replace it."
  fi

  log "Checking ports 80/443."
  check_ports

  log "Preparing Caddy user and directories."
  ensure_user_and_dirs

  if [[ ! -f "${ENV_FILE}" ]]; then
    token="$(read_token)"
  else
    log "Keeping existing Cloudflare token in ${ENV_FILE}."
  fi

  ensure_caddy_binary

  log "Writing systemd service and base Caddyfile."
  tmpdir="$(mktemp -d)"
  env_state="$(backup_path_state "${ENV_FILE}" "${tmpdir}/caddy.env")"
  service_state="$(backup_path_state "${SERVICE_FILE}" "${tmpdir}/caddy.service")"
  caddyfile_state="$(backup_path_state "${CADDYFILE}" "${tmpdir}/Caddyfile")"

  set +e
  if [[ -n "${token}" ]]; then
    run_step write_env_file "${token}"
    init_status=$?
  fi
  if [[ "${init_status}" -eq 0 ]]; then
    run_step write_service "${force}"
    init_status=$?
  fi
  if [[ "${init_status}" -eq 0 ]]; then
    run_step write_base_caddyfile "${force}"
    init_status=$?
  fi
  if [[ "${init_status}" -eq 0 ]]; then
    run_step reload_caddy
    init_status=$?
  fi
  set -e

  if [[ "${init_status}" -ne 0 ]]; then
    warn "Initialization failed. Rolling back changed config files."
    restore_path_state "${ENV_FILE}" "${tmpdir}/caddy.env" "${env_state}"
    restore_path_state "${SERVICE_FILE}" "${tmpdir}/caddy.service" "${service_state}"
    restore_path_state "${CADDYFILE}" "${tmpdir}/Caddyfile" "${caddyfile_state}"
    systemctl daemon-reload || true
    rm -rf "${tmpdir}"
    fail "Caddy failed to initialize; rolled back config files."
  fi

  rm -rf "${tmpdir}"
  install_shortcut
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
  install_shortcut
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
  local purge="false" shortcut_target="" script_target=""
  if [[ "${1:-}" == "--purge" ]]; then
    purge="true"
    shift
  fi
  [[ "$#" -eq 0 ]] || fail "Usage: $0 uninstall [--purge]"

  if [[ "${purge}" == "true" ]]; then
    confirm_purge
  fi

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
    script_target="$(resolve_self_path 2>/dev/null || true)"
    [[ -z "${script_target}" ]] || script_target="$(readlink -f "${script_target}" 2>/dev/null || true)"
    shortcut_target="$(readlink -f "${SHORTCUT_BIN}" 2>/dev/null || true)"
    if [[ -n "${shortcut_target}" && ( "${shortcut_target}" == "${script_target}" || "${shortcut_target}" == "/usr/local/bin/caddy.sh" ) ]]; then
      rm -f "${SHORTCUT_BIN}"
    fi
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
      rm -f "${backup}"
    fi
    fail "Failed to update Cloudflare token; rolled back."
  fi
  [[ -z "${backup}" ]] || rm -f "${backup}"
  log "Cloudflare token updated."
}

validate_proxy_target() {
  local port target="$1"
  if [[ "${target}" =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[2]}"
  elif [[ "${target}" =~ ^[A-Za-z0-9._-]+:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  else
    fail "Invalid proxy target: ${target}"
  fi
  validate_port "${port}"
}

add_site() {
  local backup="" domain="$1" proxy_target="$2" site_file tmp
  validate_domain "${domain}"
  validate_proxy_target "${proxy_target}"
  [[ -f "${CADDYFILE}" ]] || fail "Missing ${CADDYFILE}. Run: $0 init"
  [[ -f "${ENV_FILE}" ]] || fail "Missing ${ENV_FILE}. Run: $0 init"
  [[ -d "${SITES_DIR}" ]] || fail "Missing ${SITES_DIR}. Run: $0 init"

  site_file="$(site_file_for_domain "${domain}")"
  tmp="$(mktemp)"
  cat > "${tmp}" <<EOF
${domain} {
    import CF_CERT
    reverse_proxy ${proxy_target}
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
  log "Enabled ${domain} -> ${proxy_target}"
}

cmd_add() {
  local domain="${1:-}" port="${2:-}"
  [[ "$#" -eq 2 ]] || fail "Usage: $0 add DOMAIN LOCAL_PORT"
  validate_port "${port}"
  add_site "${domain}" "127.0.0.1:${port}"
}

parse_listener_address() {
  local address="$1"
  LISTENER_HOST=""
  LISTENER_PORT=""
  if [[ "${address}" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
    LISTENER_HOST="${BASH_REMATCH[1]}"
    LISTENER_PORT="${BASH_REMATCH[2]}"
  elif [[ "${address}" =~ ^(.+):([0-9]+)$ ]]; then
    LISTENER_HOST="${BASH_REMATCH[1]}"
    LISTENER_PORT="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  validate_port "${LISTENER_PORT}"
}

proxy_target_for_listener() {
  local host="$1" port="$2"
  case "${host}" in
    0.0.0.0|\*|"")
      printf '127.0.0.1:%s' "${port}"
      ;;
    ::|\[::\])
      printf '[::1]:%s' "${port}"
      ;;
    *:*)
      printf '[%s]:%s' "${host}" "${port}"
      ;;
    *)
      printf '%s:%s' "${host}" "${port}"
      ;;
  esac
}

skip_quick_candidate() {
  local port="$1" process_info="${2,,}"
  if ((10#${port} < 1024)); then
    return 0
  fi

  case "${port}" in
    3128|8006)
      return 0
      ;;
  esac

  case "${process_info}" in
    *sshd*|*rpcbind*|*tailscaled*|*cloudflared*|*pvedaemon*|*pveproxy*|*spiceproxy*)
      return 0
      ;;
  esac

  return 1
}

shorten_text() {
  local max="${2:-70}" text="$1"
  if ((${#text} > max)); then
    printf '%s...' "${text:0:$((max - 3))}"
  else
    printf '%s' "${text}"
  fi
}

collect_listener_candidates() {
  local key line local_addr output="$1" port process_info state target
  declare -A seen=()
  : > "${output}"

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    IFS=' ' read -r state _ _ local_addr _ process_info <<< "${line}"
    [[ "${state}" == "LISTEN" ]] || continue
    parse_listener_address "${local_addr}" || continue
    port="${LISTENER_PORT}"
    [[ "${port}" != "80" && "${port}" != "443" ]] || continue
    process_info="${process_info:-unknown}"
    skip_quick_candidate "${port}" "${process_info}" && continue
    target="$(proxy_target_for_listener "${LISTENER_HOST}" "${port}")"
    key="${port}|${target}"
    [[ -z "${seen[${key}]:-}" ]] || continue
    seen["${key}"]="1"
    printf '%s\t%s\t%s\t%s\n' "${port}" "${LISTENER_HOST}" "${target}" "${process_info}" >> "${output}"
  done < <(ss -H -ltnp 2>/dev/null || true)

  sort -t $'\t' -k1,1n -k2,2 -o "${output}" "${output}"
}

candidate_count() {
  local file="$1"
  wc -l < "${file}" | tr -d '[:space:]'
}

print_listener_candidates() {
  local file="$1" host index=0 port process_info short_process target
  while IFS=$'\t' read -r port host target process_info; do
    index=$((index + 1))
    short_process="$(shorten_text "${process_info:-unknown}" 64)"
    printf ' %2d) %-22s -> %-22s %s\n' "${index}" "${host}:${port}" "${target}" "${short_process}"
  done < "${file}"
}

ensure_initialized_for_quick() {
  if [[ -f "${CADDYFILE}" && -f "${ENV_FILE}" && -d "${SITES_DIR}" ]]; then
    return
  fi

  tty_read "Caddy 尚未初始化，是否现在初始化？[Y/n]: "
  case "${REPLY}" in
    ""|y|Y|yes|YES)
      cmd_init
      ;;
    *)
      fail "Quick connect requires initialized Caddy."
      ;;
  esac
}

cmd_quick() {
  local candidate choice count domain port selected target tmp
  [[ "$#" -eq 0 ]] || fail "Usage: $0 quick"
  have_tty || fail "No TTY available for quick connect."

  ensure_initialized_for_quick
  tmp="$(mktemp)"

  while true; do
    collect_listener_candidates "${tmp}"
    count="$(candidate_count "${tmp}")"

    printf '\n'
    printf '======== AI 快速对接 ========\n'
    if [[ "${count}" -gt 0 ]]; then
      printf '检测到这些本机监听服务：\n'
      print_listener_candidates "${tmp}"
    else
      warn "No local TCP listeners were detected."
    fi
    printf '%s\n' '----------------------------'
    printf ' m) 手动输入本地端口\n'
    printf ' r) 重新扫描\n'
    printf ' 0) 取消\n'

    tty_read "请选择服务编号 / m / r / 0: "
    choice="${REPLY}"
    case "${choice}" in
      0|q|Q|exit)
        rm -f "${tmp}"
        log "Cancelled."
        return
        ;;
      r|R)
        continue
        ;;
      m|M)
        tty_read "本地端口，例如 8080: "
        port="${REPLY}"
        validate_port "${port}"
        target="127.0.0.1:${port}"
        ;;
      ''|*[!0-9]*)
        warn "Invalid choice: ${choice}"
        continue
        ;;
      *)
        selected=$((10#${choice}))
        if (( selected < 1 || selected > count )); then
          warn "Invalid choice: ${choice}"
          continue
        fi
        candidate="$(sed -n "${selected}p" "${tmp}")"
        IFS=$'\t' read -r port _host target _process_info <<< "${candidate}"
        ;;
    esac

    tty_read "对外域名，例如 app.example.com: "
    domain="${REPLY}"
    validate_domain "${domain}"

    printf '即将创建：%s -> %s\n' "${domain}" "${target}"
    tty_read "确认？[Y/n]: "
    case "${REPLY}" in
      ""|y|Y|yes|YES)
        rm -f "${tmp}"
        add_site "${domain}" "${target}"
        return
        ;;
      *)
        rm -f "${tmp}"
        log "Cancelled."
        return
        ;;
    esac
  done
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
  local file domain proxy nullglob_was_set="false"
  shopt -q nullglob && nullglob_was_set="true"
  shopt -s nullglob
  for file in "${SITES_DIR}"/*.caddy; do
    [[ "$(basename "${file}")" != "00-empty.caddy" ]] || continue
    domain="$(grep -m1 -E '^[^[:space:]#][^{]*\{' "${file}" | sed -E 's/[[:space:]]*\{[[:space:]]*$//' || true)"
    proxy="$(grep -m1 -E '^[[:space:]]*reverse_proxy[[:space:]]+' "${file}" | sed -E 's/^[[:space:]]*reverse_proxy[[:space:]]+//' || true)"
    printf '%s -> %s\n' "${domain:-$(basename "${file}" .caddy)}" "${proxy:-unknown}"
  done
  [[ "${nullglob_was_set}" == "true" ]] || shopt -u nullglob
}

menu_status() {
  local caddy_version="not installed" nullglob_was_set="false" service_state="not installed" site_count="0"
  if [[ -x "${CADDY_BIN}" ]]; then
    caddy_version="$(${CADDY_BIN} version 2>/dev/null || printf 'installed')"
  fi
  if systemctl list-unit-files caddy.service >/dev/null 2>&1 || [[ -f "${SERVICE_FILE}" ]]; then
    service_state="$(systemctl is-active caddy 2>/dev/null || true)"
    [[ -n "${service_state}" ]] || service_state="inactive"
  fi
  if [[ -d "${SITES_DIR}" ]]; then
    shopt -q nullglob && nullglob_was_set="true"
    shopt -s nullglob
    local files=("${SITES_DIR}"/*.caddy)
    site_count="${#files[@]}"
    [[ -f "${SITES_DIR}/00-empty.caddy" && "${site_count}" -gt 0 ]] && site_count="$((site_count - 1))"
    [[ "${nullglob_was_set}" == "true" ]] || shopt -u nullglob
  fi

  printf 'Caddy: %s\n' "${caddy_version}"
  printf 'Service: %s\n' "${service_state}"
  printf 'Sites: %s\n' "${site_count}"
}

menu_run() {
  local status
  set +e
  run_step "$@"
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    log "Done."
  else
    warn "Operation failed with exit code ${status}."
  fi
  menu_pause
}

cmd_menu() {
  local choice domain port version purge_choice
  [[ "$#" -eq 0 ]] || fail "Usage: $0 menu"
  have_tty || fail "No TTY available for interactive menu."

  while true; do
    printf '\n'
    printf '======== caddy.sh 管理菜单 ========\n'
    menu_status
    printf '%s\n' '-----------------------------------'
    printf ' 1) 初始化 / 安装 Caddy\n'
    printf ' 2) AI 快速对接本机服务\n'
    printf ' 3) 手动添加 / 更新反代站点\n'
    printf ' 4) 删除站点\n'
    printf ' 5) 查看站点列表\n'
    printf ' 6) 校验并重载 Caddy\n'
    printf ' 7) 更新 Cloudflare Token\n'
    printf ' 8) 更新 Caddy 二进制\n'
    printf ' 9) 更新脚本自身\n'
    printf '10) 卸载 Caddy\n'
    printf ' 0) 退出\n'
    printf '===================================\n'

    tty_read "请选择 [0-10]: "
    choice="${REPLY}"
    case "${choice}" in
      1)
        menu_run cmd_init
        ;;
      2)
        menu_run cmd_quick
        ;;
      3)
        tty_read "域名，例如 example.com: "
        domain="${REPLY}"
        tty_read "本地端口，例如 8080: "
        port="${REPLY}"
        menu_run cmd_add "${domain}" "${port}"
        ;;
      4)
        ( cmd_list ) || true
        tty_read "要删除的域名: "
        domain="${REPLY}"
        menu_run cmd_remove "${domain}"
        ;;
      5)
        menu_run cmd_list
        ;;
      6)
        menu_run cmd_reload
        ;;
      7)
        menu_run cmd_set_token
        ;;
      8)
        tty_read "Caddy 版本，留空使用 ${CADDY_VERSION}: "
        version="${REPLY}"
        if [[ -n "${version}" ]]; then
          menu_run cmd_upgrade_caddy "${version}"
        else
          menu_run cmd_upgrade_caddy
        fi
        ;;
      9)
        menu_run cmd_self_update
        ;;
      10)
        printf ' 1) 卸载，保留 /etc/caddy 和 /var/lib/caddy\n'
        printf ' 2) 彻底卸载，同时删除配置、数据和 caddy 用户/组\n'
        tty_read "请选择 [1-2]: "
        purge_choice="${REPLY}"
        case "${purge_choice}" in
          1) menu_run cmd_uninstall ;;
          2) menu_run cmd_uninstall --purge ;;
          *) warn "Invalid choice."; menu_pause ;;
        esac
        ;;
      0|q|Q|exit)
        exit 0
        ;;
      *)
        warn "Invalid choice: ${choice}"
        menu_pause
        ;;
    esac
  done
}

main() {
  local cmd="${1:-}"

  case "${cmd}" in
    help|-h|--help)
      usage
      exit 0
      ;;
  esac

  ensure_root "$@"
  need_command systemctl
  need_command grep
  need_command install
  need_command ln
  need_command readlink
  need_command sed
  need_command ss

  if [[ -z "${cmd}" ]]; then
    cmd_menu
    exit 0
  fi
  shift || true

  case "${cmd}" in
    menu) cmd_menu "$@" ;;
    init) cmd_init "$@" ;;
    set-token) cmd_set_token "$@" ;;
    quick|ai|wizard) cmd_quick "$@" ;;
    add) cmd_add "$@" ;;
    remove|rm|delete) cmd_remove "$@" ;;
    list|ls) cmd_list "$@" ;;
    reload) cmd_reload "$@" ;;
    self-update|update-script) cmd_self_update "$@" ;;
    upgrade-caddy|update-caddy) cmd_upgrade_caddy "$@" ;;
    uninstall|remove-caddy) cmd_uninstall "$@" ;;
    *) usage; fail "Unknown command: ${cmd}" ;;
  esac
}

main "$@"
