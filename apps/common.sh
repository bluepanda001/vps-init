#!/usr/bin/env bash

APP_STATE_DIR="${STATE_DIR}/apps"
APP_ROOT="/opt/vps-apps"

app_require_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || die "非法应用 ID：$1"
}

app_state_file() {
  app_require_id "$1"
  printf '%s/%s.env\n' "$APP_STATE_DIR" "$1"
}

app_state_load() {
  local id="$1" f
  f="$(app_state_file "$id")"
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC1090
  source "$f"
}

app_state_set() {
  local id="$1" key="$2" value="$3" f tmp
  f="$(app_state_file "$id")"
  mkdir -p "$APP_STATE_DIR"
  touch "$f"; chmod 600 "$f"
  tmp="$(mktemp)"
  grep -v -E "^${key}=" "$f" > "$tmp" || true
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  install -m 600 "$tmp" "$f"
  rm -f "$tmp"
  export "$key=$value"
}

app_state_exists() {
  [[ -f "$(app_state_file "$1")" ]]
}

app_local_http_ok() {
  local port="$1" path="${2:-/}" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}${path}" 2>/dev/null || true)"
  [[ "$code" =~ ^[23] ]]
}

app_wait_http() {
  local port="$1" path="${2:-/}" tries="${3:-40}" i
  for ((i=1;i<=tries;i++)); do
    app_local_http_ok "$port" "$path" && return 0
    sleep 1
  done
  return 1
}

app_select_port() {
  local preferred="$1"
  if ! port_in_use "$preferred"; then
    printf '%s\n' "$preferred"
  else
    random_port
  fi
}

app_validate_domain() {
  local d="$1"
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$d" == *.* && "$d" != *..* ]]
}

app_core_context() {
  [[ -f "$DEFAULT_CFG" ]] || die "尚无 VPS Init 核心配置；请先完成核心部署。"
  load_runtime_config "$DEFAULT_CFG"
  state_load
}
