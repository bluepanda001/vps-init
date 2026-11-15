#!/usr/bin/env bash
# Progress is separate from state.env so it cannot imply component adoption.
deployment_record() {
  local status="$1" step="$2" rc="${3:-0}" tmp
  tmp="$(mktemp "$STATE_DIR/.deployment.XXXXXX")"
  printf 'STATUS=%q\nSTEP=%q\nEXIT_CODE=%q\nPROFILE=%q\n' "$status" "$step" "$rc" "$PROFILE" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_DIR/deployment.env"
}
deployment_exit() {
  local rc="$1"
  if [[ "${DEPLOYMENT_FINISHED:-false}" != true ]]; then
    deployment_record interrupted "${DEPLOYMENT_STEP:-prepare}" "$rc"
    log_warn "部署停在 ${DEPLOYMENT_STEP:-prepare}（exit=${rc}）。配置已保存；运行 vps-init resume 继续，或 apply 按已验证配置修复。"
  fi
}
deployment_begin() {
  local cfg="$1"
  ensure_dir "$STATE_DIR"
  exec 9>"$STATE_DIR/deploy.lock"
  flock -n 9 || die "已有部署正在运行，请等待完成。"
  ensure_dir "$PERSIST_DIR"
  if [[ "$(readlink -f "$cfg")" != "$(readlink -f "$PERSIST_DIR/pending.env" 2>/dev/null || true)" ]]; then
    atomic_config_copy "$cfg" "$PERSIST_DIR/pending.env"
  fi
  DEPLOYMENT_FINISHED=false
  DEPLOYMENT_STEP=prepare
  trap 'deployment_exit $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
deployment_step() {
  DEPLOYMENT_STEP="$1"
  deployment_record running "$DEPLOYMENT_STEP"
  log_info "执行阶段：$DEPLOYMENT_STEP"
  # Must not be invoked under if/&&/||, which suppress Bash errexit.
  "$@"
  deployment_record completed "$DEPLOYMENT_STEP"
}
resume_deployment() {
  [[ -f "$PERSIST_DIR/pending.env" ]] || die "没有待恢复配置；请使用 apply 或 wizard。"
  exec "$ROOT_DIR/vps-init" apply "$PERSIST_DIR/pending.env"
}
