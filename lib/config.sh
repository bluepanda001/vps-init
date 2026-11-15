#!/usr/bin/env bash
persist_config() {
  local src="$1" dst="$PERSIST_DIR/config.env"
  ensure_dir "$PERSIST_DIR"
    local clean
    clean="$(mktemp "${dst}.clean.XXXXXX")"
    # Transient wizard credentials/migration authorization must not survive commit.
    grep -Ev '^VPSINIT_(ALLOW_PROFILE_SWITCH|XUI_USERNAME_INPUT|XUI_PASSWORD_INPUT|LUCKY_USERNAME_INPUT|LUCKY_PASSWORD_INPUT)=' "$src" > "$clean" || [[ $? == 1 ]]
    atomic_config_copy "$clean" "$dst"
    rm -f "$clean"
}

atomic_config_copy() {
  local src="$1" dst="$2" tmp
  tmp="$(mktemp "${dst}.tmp.XXXXXX")"
  install -m 600 "$src" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dst"
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
  DOCKER_INSTALL_SOURCE="official"
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
