#!/usr/bin/env bash
state_set() {
  local key="$1" value="$2" tmp
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "无效状态字段。"
  ensure_dir "$STATE_DIR"; touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  grep -v -E "^${key}=" "$STATE_FILE" > "$tmp" || true
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
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
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "无效凭据字段。"
  [[ "$value" != *$'\n'* ]] || die "凭据不能包含换行。"
  touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  grep -v -E "^${key}=" "$SECRETS_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$SECRETS_FILE"
}

