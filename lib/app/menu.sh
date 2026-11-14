#!/usr/bin/env bash
update_self() {
  local source_file="$PERSIST_DIR/.source.env" repo ref
  [[ -r "$source_file" ]] || die "未记录 GitHub 来源。请重新运行项目 README 中的一键安装命令。"
  # shellcheck disable=SC1090
  source "$source_file"
  repo="${VPSINIT_REPO:-}"; ref="${VPSINIT_BOOTSTRAP_REF:-main}"
  [[ -n "$repo" && "$repo" == */* ]] || die "GitHub 仓库来源尚未配置。"
  log_info "从 GitHub 更新 VPS Init：${repo}@${ref}"
  # Reuse the already installed bootstrap instead of executing a newly fetched
  # unverified install.sh. The bootstrap itself prefers SHA256-verified Releases.
  VPSINIT_REPO="$repo" VPSINIT_BOOTSTRAP_REF="$ref" bash "$ROOT_DIR/install.sh" --update --no-menu
  log_ok "更新完成。重新执行：vps-init"
}

edit_config_file() {
  local config_file="$1" requested="${EDITOR:-}" candidate
  local -a editor_cmd=()
  if [[ -n "$requested" ]]; then
    read -r -a editor_cmd <<<"$requested"
    if (( ${#editor_cmd[@]} > 0 )) && command_exists "${editor_cmd[0]}"; then
      "${editor_cmd[@]}" "$config_file"
      return $?
    fi
    log_warn "指定的 EDITOR 不存在：$requested；尝试其他已安装编辑器。"
  fi
  for candidate in nano vi vim; do
    if command_exists "$candidate"; then
      "$candidate" "$config_file"
      return $?
    fi
  done
  log_warn "系统缺少文本编辑器，正在安装 nano..."
  wait_apt_lock 300
  export DEBIAN_FRONTEND=noninteractive
  apt_get_with_lock_retry update
  apt_get_with_lock_retry install -y nano
  command_exists nano || die "nano 安装完成后仍不可用，请检查系统软件源。"
  nano "$config_file"
}

edit_config_safe() {
  local config_file="$1" draft rc=0
  [[ -f "$config_file" ]] || die "尚无配置，请先运行向导。"
  draft="$(mktemp "${config_file}.edit.XXXXXX")"
  atomic_config_copy "$config_file" "$draft"
  edit_config_file "$draft" || rc=$?
  if (( rc == 0 )); then
    "$ROOT_DIR/vps-init" validate "$draft" || rc=$?
  fi
  if (( rc == 0 )); then
    atomic_config_copy "$draft" "$config_file"
    log_ok "配置已保存；运行 apply 应用。"
  else
    log_warn "编辑或校验失败，原配置未修改。"
  fi
  rm -f "$draft"
  return "$rc"
}

menu() {
  require_root
  [[ -t 0 ]] || die "交互菜单需要 TTY。"
  while true; do
    clear 2>/dev/null || true
    wizard_banner
    echo
    [[ -f "$DEFAULT_CFG" ]] && { state_load; echo "当前 Profile：${DEPLOYED_PROFILE:-未部署}"; echo; }
    cat <<'TXT'
【安装与部署】
  1. 应用当前配置 / 首次部署（也用于修复）
 15. 继续上次失败或中断的部署
 11. 重新选择安装方案
【系统与服务】
  2. 运行核心验收          3. 查看部署信息
  4. 查看当前状态          7. Web Gateway / Lucky
【配置与凭据】
  5. 查看敏感凭据          6. 修改管理账号 / 密码
  8. 编辑并校验配置（保存后按 1 应用）
【网络工具】
 14. TCPFit 调优 / TcpQuality 测速
【更新与维护】
  9. 更新 VPS Init         10. 查看服务日志
 13. 系统完整升级（apt upgrade）
【系统重装】
 12. 一键 DD（清空系统盘，需输入 DD 确认）
  0. 退出
TXT
    local n
    read -r -p "请选择 [0-15]: " n || return 0
    case "$n" in
      1)
        if [[ -f "$DEFAULT_CFG" ]]; then
          "$ROOT_DIR/vps-init" apply "$DEFAULT_CFG" || true
        else
          local wizard_rc=0
          "$ROOT_DIR/vps-init" wizard || wizard_rc=$?
          (( wizard_rc == 42 )) && exit 0
        fi
        ;;
      2) "$ROOT_DIR/vps-init" verify "$DEFAULT_CFG" || true ;;
      3) "$ROOT_DIR/vps-init" info "$DEFAULT_CFG" || true ;;
      4) "$ROOT_DIR/vps-init" status "$DEFAULT_CFG" || true ;;
      5)
        if [[ -f "$SECRETS_FILE" ]]; then
          echo "警告：下面包含密码、API Token/节点参数等敏感信息。"
          if wizard_yesno "确认显示？" n; then "$ROOT_DIR/vps-init" secrets || true; fi
        else echo "尚未生成凭据文件。"; fi
        ;;
      6) "$ROOT_DIR/vps-init" passwd || true ;;
      7) "$ROOT_DIR/vps-init" gateway || true ;;
      8)
        [[ -f "$DEFAULT_CFG" ]] || { echo "尚无配置，先运行安装向导。"; "$ROOT_DIR/vps-init" wizard || true; continue; }
        "$ROOT_DIR/vps-init" edit-config "$DEFAULT_CFG" || true
        ;;
      9) "$ROOT_DIR/vps-init" update || true ;;
      10) "$ROOT_DIR/vps-init" logs || true ;;
      11)
        local wizard_rc=0
        "$ROOT_DIR/vps-init" wizard || wizard_rc=$?
        (( wizard_rc == 42 )) && exit 0
        ;;
      12) "$ROOT_DIR/vps-init" reinstall || true ;;
      13) "$ROOT_DIR/vps-init" upgrade-system || true ;;
      14) "$ROOT_DIR/vps-init" network-tools || true ;;
      15) "$ROOT_DIR/vps-init" resume || true ;;
      0) exit 0 ;;
      *) echo "输入无效。" ;;
    esac
    echo
    read -r -p "按 Enter 返回菜单..." _ || return 0
  done
}

