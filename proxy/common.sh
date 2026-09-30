#!/usr/bin/env bash

PROXY_STATE_DIR="${STATE_DIR}/proxies"

proxy_validate_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || die "反代 ID 只允许小写字母、数字、_、-，长度 1-32。"
}

proxy_state_file() {
  proxy_validate_id "$1"
  printf '%s/%s.env\n' "$PROXY_STATE_DIR" "$1"
}

proxy_state_load() {
  local f
  f="$(proxy_state_file "$1")"
  [[ -f "$f" ]] || return 1
  # shellcheck disable=SC1090
  source "$f"
}

proxy_state_set() {
  local id="$1" key="$2" value="$3" f tmp
  f="$(proxy_state_file "$id")"
  mkdir -p "$PROXY_STATE_DIR"
  touch "$f"; chmod 600 "$f"
  tmp="$(mktemp)"
  grep -v -E "^${key}=" "$f" > "$tmp" || true
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  install -m 600 "$tmp" "$f"
  rm -f "$tmp"
}

proxy_list_ids() {
  mkdir -p "$PROXY_STATE_DIR"
  local f
  shopt -s nullglob
  for f in "$PROXY_STATE_DIR"/*.env; do basename "$f" .env; done
  shopt -u nullglob
}

proxy_domain_allowed() {
  local domain="$1" root="$2"
  [[ "$domain" == "$root" ]] && return 0
  [[ "$domain" == *."$root" ]] || return 1
  local prefix="${domain%.$root}"
  [[ -n "$prefix" && "$prefix" != *.* ]]
}

proxy_upstream_reachable() {
  local scheme="$1" host="$2" port="$3" path="${4:-/}" tls_verify="${5:-true}"
  local args=(-sS -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8)
  if [[ "$scheme" == "https" ]] && ! is_true "$tls_verify"; then args+=(-k); fi
  local code
  code="$(curl "${args[@]}" "${scheme}://${host}:${port}${path}" 2>/dev/null || true)"
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]
}

proxy_port_exposure() {
  local port="$1"
  ss -H -ltn "sport = :${port}" 2>/dev/null | awk '{print $4}' | sort -u
}

proxy_load_core() {
  [[ -f "$DEFAULT_CFG" ]] || die "尚无核心配置，请先完成 VPS Init 核心部署。"
  load_runtime_config "$DEFAULT_CFG"
  state_load
  profile_has_domain || die "反向代理中心当前需要域名 Profile（nginx-reality / lucky-reality）。"
  [[ -n "${ROOT_DOMAIN:-}" ]] || die "ROOT_DOMAIN 为空。"
}
