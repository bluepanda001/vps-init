#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="/var/lib/vps-init"
STATE_FILE="${STATE_DIR}/state.env"
SECRETS_FILE="/root/vps-init-secrets.txt"
REPORT_FILE="/root/vps-init-report.txt"
PERSIST_DIR="/opt/vps-init"
BACKUP_ROOT="/var/backups/vps-init"
RUN_TS="${RUN_TS:-$(date -u '+%Y%m%dT%H%M%SZ')}"
BACKUP_DIR="${BACKUP_ROOT}/${RUN_TS}"

# shellcheck source=log.sh
source "${ROOT_DIR}/lib/log.sh"

trap 'rc=$?; log_error "命令失败（exit=${rc}）: ${BASH_COMMAND}"; exit "$rc"' ERR

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
ensure_dir() { mkdir -p "$1"; }

is_true() {
  case "${1:-}" in 1|true|TRUE|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac
}

random_hex() { openssl rand -hex "${1:-8}"; }
random_b64url() {
  local bytes="${1:-24}" want="${2:-24}" raw=""
  while ((${#raw} < want)); do
    local chunk
    chunk="$(openssl rand -base64 "$bytes")"
    chunk="${chunk//$'\n'/}"
    chunk="${chunk//=/}"
    chunk="${chunk//+/}"
    chunk="${chunk//\//}"
    raw+="$chunk"
  done
  printf '%s\n' "${raw:0:want}"
}
random_port() {
  python3 - <<'PY2'
import random, socket
for _ in range(300):
    p=random.randint(12000,60000)
    s=socket.socket()
    try:
        s.bind(('127.0.0.1',p))
    except OSError:
        s.close(); continue
    s.close(); print(p); break
else:
    raise SystemExit('no free port')
PY2
}

shell_quote() { printf '%q' "$1"; }
state_set() {
  local key="$1" value="$2" tmp
  ensure_dir "$STATE_DIR"; touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
  tmp="$(mktemp)"
  grep -v -E "^${key}=" "$STATE_FILE" > "$tmp" || true
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  install -m 600 "$tmp" "$STATE_FILE"
  rm -f "$tmp"
  export "$key=$value"
}
state_load() {
  ensure_dir "$STATE_DIR"
  if [[ -f "$STATE_FILE" ]]; then
    # root-only state created by this project.
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

secret_set() {
  local key="$1" value="$2" tmp
  touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
  tmp="$(mktemp)"
  grep -v -E "^${key}=" "$SECRETS_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  install -m 600 "$tmp" "$SECRETS_FILE"
  rm -f "$tmp"
}

copy_project_persistent() {
  ensure_dir "$PERSIST_DIR"
  if [[ "$(readlink -f "$ROOT_DIR")" != "$(readlink -f "$PERSIST_DIR")" ]]; then
    tar -C "$ROOT_DIR" --exclude='.git' --exclude='config.env' --exclude='__pycache__' --exclude='*.pyc' --exclude='*.pyo' -cf - . | tar -C "$PERSIST_DIR" -xf -
  fi
  chmod +x "$PERSIST_DIR/vps-init" 2>/dev/null || true
}

persist_config() {
  local src="$1" dst="$PERSIST_DIR/config.env"
  ensure_dir "$PERSIST_DIR"
  if [[ "$(readlink -f "$src")" == "$(readlink -f "$dst" 2>/dev/null || printf '%s' "$dst")" ]]; then
    chmod 600 "$dst"
  else
    install -m 600 "$src" "$dst"
  fi
}

wait_apt_lock() {
  local timeout="${1:-300}" waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    (( waited >= timeout )) && die "等待 apt/dpkg 锁超时。"
    sleep 3; waited=$((waited+3))
  done
}

http_get() { curl -fsSL --connect-timeout 8 --max-time 20 "$1"; }

is_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip" || return 1
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  ((a>=0 && a<=255 && b>=0 && b<=255 && c>=0 && c<=255 && d>=0 && d<=255))
}

is_private_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip" || return 1
  (( a==10 || a==127 || (a==169 && b==254) || (a==172 && b>=16 && b<=31) || (a==192 && b==168) || (a==100 && b>=64 && b<=127) ))
}

get_public_ipv4() {
  local ip=""
  for u in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me; do
    ip="$(curl -4fsS --connect-timeout 3 --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$ip"; then printf '%s\n' "$ip"; return 0; fi
  done
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
  is_ipv4 "$ip" || return 1
  printf '%s\n' "$ip"
}

get_public_ipv6() {
  local ip
  ip="$(curl -6fsS --connect-timeout 3 --max-time 5 https://api6.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$ip" == *:* ]] && printf '%s\n' "$ip" || true
}

get_default_interface() {
  ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

port_in_use() { ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }

confirm() {
  local prompt="$1" default="${2:-n}" reply
  if [[ ! -t 0 ]]; then return 1; fi
  if [[ "$default" == "y" ]]; then read -r -p "$prompt [Y/n] " reply; reply="${reply:-y}";
  else read -r -p "$prompt [y/N] " reply; reply="${reply:-n}"; fi
  [[ "$reply" =~ ^[Yy]$ ]]
}

normalize_path() {
  local p="$1"
  [[ "$p" == /* ]] || p="/$p"
  [[ "$p" == */ ]] || p="$p/"
  printf '%s' "$p"
}

cert_key_match() {
  local cert="$1" key="$2" cert_fp key_fp
  [[ -s "$cert" && -s "$key" ]] || return 1
  cert_fp="$(
    openssl x509 -in "$cert" -pubkey -noout 2>/dev/null |
      openssl pkey -pubin -outform DER 2>/dev/null |
      sha256sum | awk '{print $1}'
  )"
  key_fp="$(
    openssl pkey -in "$key" -pubout -outform DER 2>/dev/null |
      sha256sum | awk '{print $1}'
  )"
  [[ -n "$cert_fp" && "$cert_fp" == "$key_fp" ]]
}

cert_has_ip_san() {
  local cert="$1" ip="$2"
  openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null |
    grep -Fq "IP Address:${ip}"
}

profile_has_domain() { [[ "$PROFILE" == "nginx-reality" || "$PROFILE" == "lucky-reality" || "$PROFILE" == "lucky-web" ]]; }
profile_has_xui() { [[ "$PROFILE" == "reality-only" || "$PROFILE" == "nginx-reality" || "$PROFILE" == "lucky-reality" ]]; }
profile_has_lucky() { [[ "$PROFILE" == "lucky-reality" || "$PROFILE" == "lucky-web" ]]; }

resolve_auto_settings() {
  case "$PROFILE" in
    base-only|lucky-web)
      ENABLE_SUBSCRIPTION_RESOLVED=false; SUBSCRIPTION_EXPOSE_MODE_RESOLVED="none" ;;
    reality-only)
      ENABLE_SUBSCRIPTION_RESOLVED=true; SUBSCRIPTION_EXPOSE_MODE_RESOLVED="direct-ip-https" ;;
    nginx-reality)
      ENABLE_SUBSCRIPTION_RESOLVED=true; SUBSCRIPTION_EXPOSE_MODE_RESOLVED="nginx-https" ;;
    lucky-reality)
      ENABLE_SUBSCRIPTION_RESOLVED=true; SUBSCRIPTION_EXPOSE_MODE_RESOLVED="lucky-https" ;;
    *) die "未知 PROFILE: $PROFILE" ;;
  esac
  [[ "$ENABLE_SUBSCRIPTION" != "auto" ]] && ENABLE_SUBSCRIPTION_RESOLVED="$ENABLE_SUBSCRIPTION"
  [[ "$SUBSCRIPTION_EXPOSE_MODE" != "auto" ]] && SUBSCRIPTION_EXPOSE_MODE_RESOLVED="$SUBSCRIPTION_EXPOSE_MODE"
  # Once a subscription port has been selected on this VPS, keep it stable
  # across idempotent reruns even if the original requested port later changes.
  [[ -n "${SUBSCRIPTION_PORT_SELECTED:-}" ]] && SUBSCRIPTION_PORT="$SUBSCRIPTION_PORT_SELECTED"

  if profile_has_domain; then
    LUCKY_DOMAIN="${LUCKY_DOMAIN_OVERRIDE:-lucky.${ROOT_DOMAIN}}"
    PANEL_DOMAIN="${PANEL_DOMAIN_OVERRIDE:-xui.${ROOT_DOMAIN}}"
    NODE_DOMAIN="${NODE_DOMAIN_OVERRIDE:-node.${ROOT_DOMAIN}}"
  else
    LUCKY_DOMAIN=""; PANEL_DOMAIN=""; NODE_DOMAIN=""
  fi
  export ENABLE_SUBSCRIPTION_RESOLVED SUBSCRIPTION_EXPOSE_MODE_RESOLVED LUCKY_DOMAIN PANEL_DOMAIN NODE_DOMAIN
}


resolve_runtime_ports() {
  is_true "${ENABLE_SUBSCRIPTION_RESOLVED:-false}" || return 0
  state_load
  if [[ -n "${SUBSCRIPTION_PORT_SELECTED:-}" ]]; then
    SUBSCRIPTION_PORT="$SUBSCRIPTION_PORT_SELECTED"
    export SUBSCRIPTION_PORT
    return 0
  fi

  local requested="$SUBSCRIPTION_PORT" selected="$SUBSCRIPTION_PORT"
  if port_in_use "$requested"; then
    # Upgrade compatibility: V1.0 did not persist SUBSCRIPTION_PORT_SELECTED.
    # If the requested port is already owned by x-ui, keep it instead of
    # needlessly rotating the user's existing subscription endpoint.
    if systemctl is-active --quiet x-ui 2>/dev/null && ss -H -ltnp "sport = :${requested}" 2>/dev/null | grep -Eqi '(x-ui|xray)'; then
      selected="$requested"
    else
      selected="$(python3 - <<'PY2'
import random, socket
for _ in range(600):
    p=random.randint(12000,60000)
    s=socket.socket()
    try:
        s.bind(('0.0.0.0',p))
    except OSError:
        s.close(); continue
    s.close(); print(p); break
else:
    raise SystemExit('no free port')
PY2
)"
      log_warn "订阅端口 ${requested} 已被其他服务占用，自动改用空闲端口 ${selected}。"
    fi
  fi
  SUBSCRIPTION_PORT="$selected"
  state_set SUBSCRIPTION_PORT_SELECTED "$selected"
  export SUBSCRIPTION_PORT
}

lucky_local_version_ok() {
  # After SetSafeURL, Lucky serves /version and /api under /<safe>, and the root paths 404.
  local timeout="${1:-5}" safe="${LUCKY_SAFE_URL:-}"
  safe="${safe#/}"
  if [[ -n "$safe" ]] && curl -fsS --max-time "$timeout" -o /dev/null "http://127.0.0.1:16601/${safe}/version"; then
    return 0
  fi
  curl -fsS --max-time "$timeout" -o /dev/null "http://127.0.0.1:16601/version"
}

lucky_api() {
  local base="http://127.0.0.1:16601" safe="${LUCKY_SAFE_URL:-}"
  safe="${safe#/}"
  if [[ -n "$safe" ]] && curl -fsS --max-time 2 -o /dev/null "${base}/${safe}/version"; then
    base="${base}/${safe}"
  fi
  python3 "$ROOT_DIR/modules/lucky/lucky_api.py" --base "$base" "$@"
}

set_config_defaults() {
  PROFILE="reality-only"
  PROVIDER=""
  SERVER_NAME=""
  SSH_PORT="22"
  SSH_PUBLIC_KEY=""
  SSH_IDENTITY_HINT=""
  ROOT_DOMAIN=""
  DNS_PROVIDER="cloudflare"
  LE_EMAIL=""
  LUCKY_DOMAIN_OVERRIDE=""
  PANEL_DOMAIN_OVERRIDE=""
  NODE_DOMAIN_OVERRIDE=""
  REALITY_TARGET_MODE="auto"
  REALITY_TARGET=""
  # Avoid Cloudflare targets by default: failed REALITY authentication is
  # forwarded to target and shared-CDN targets are easier to abuse as relays.
  REALITY_CANDIDATES="dl.google.com,www.apple.com,www.google.com,github.io"
  # Fallback-only throttling; valid REALITY clients are not rate-limited.
  REALITY_FALLBACK_AFTER_BYTES="1048576"
  REALITY_FALLBACK_UPLOAD_BPS="65536"
  REALITY_FALLBACK_UPLOAD_BURST_BPS="131072"
  REALITY_FALLBACK_DOWNLOAD_BPS="131072"
  REALITY_FALLBACK_DOWNLOAD_BURST_BPS="262144"
  ENABLE_SUBSCRIPTION="auto"
  SUBSCRIPTION_EXPOSE_MODE="auto"
  SUBSCRIPTION_PORT="2096"
  XUI_PANEL_URI_PATH="/zhg/"
  XUI_SUB_URI_PATH="/zhg/"
  ENABLE_DOCKER="false"
  ENABLE_CF_WS="false"
  ENABLE_CF_PREFERRED="false"
  ENABLE_CLOUDFLARESUB="false"
}

load_config() {
  local cfg="${1:-${ROOT_DIR}/config.env}"
  if [[ ! -f "$cfg" ]]; then
    die "未找到配置文件 $cfg。请先运行 vps-init wizard，或复制 config.env.example 后编辑。"
  fi
  set_config_defaults
  # shellcheck disable=SC1090
  source "$cfg"
  resolve_auto_settings
}
