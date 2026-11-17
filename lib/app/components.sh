#!/usr/bin/env bash
# Interactive front end and serialized, resumable component operations.
component_config_set() {
  local file="$1" key="$2" value="$3" tmp
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "无效配置字段。"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  grep -v -E "^${key}=" "$file" > "$tmp" || [[ $? == 1 ]]
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}
component_load_current() {
  [[ -f "$DEFAULT_CFG" ]] || die "请先完成首次部署。"
  state_load
  [[ -n "${DEPLOYED_PROFILE:-}" ]] || die "未找到已验收的部署记录，请先完成首次部署或恢复。"
  load_config "$DEFAULT_CFG"
  validate_config
  [[ "$PROFILE" == "$DEPLOYED_PROFILE" ]] || die "配置与已部署布局不一致，请先完成原配置变更。"
}
component_status() {
  component_load_current
  printf '初始方案：%s\n当前布局：%s\n' "${INITIAL_PROFILE:-$DEPLOYED_PROFILE}" "$PROFILE"
  local id configured runtime
  while read -r id; do
    configured=未启用
    component_enabled "$id" && configured=已启用
    if systemctl is-active --quiet "$(component_service "$id")" 2>/dev/null; then
      runtime=服务运行中
    elif component_present "$id"; then runtime=已安装但服务未运行
    else runtime=未安装; fi
    if [[ "$configured" == 未启用 && "$runtime" != 未安装 ]]; then
      runtime="${runtime}（共享依赖或外部安装，不代表本功能已启用）"
    fi
    printf '  %-13s %s | %s | %s\n' "$id" "$(component_label "$id")" "$configured" "$runtime"
  done < <(component_ids)
  echo '运行状态只检查服务；功能连通性在增装/修复完成后验收。'
  if [[ -d "$STATE_DIR/component-operation" ]]; then
    echo '存在待恢复组件操作：vps-init components resume'
    [[ ! -f "$STATE_DIR/component-operation/progress" ]] || cat "$STATE_DIR/component-operation/progress"
  fi
}
component_lock() {
  ensure_dir "$STATE_DIR"
  exec 9>"$STATE_DIR/deploy.lock"
  flock -n 9 || die "已有部署或组件操作正在运行。"
  [[ ! -f "$PERSIST_DIR/pending.env" ]] || die "存在完整部署候选，请先运行 vps-init resume。"
}
component_summary() {
  printf '\n组件：%s\n操作：%s\n布局：%s -> %s\n' "$(component_label "$COMPONENT_ID")" "$COMPONENT_ACTION" "$COMPONENT_FROM_PROFILE" "$COMPONENT_TARGET_PROFILE"
  printf '执行步骤：%s\n' "${COMPONENT_STEPS[*]}"
  if [[ "$COMPONENT_ID" == docker ]]; then printf 'Docker 软件包源：%s\n' "$DOCKER_INSTALL_SOURCE"; fi
  case "$COMPONENT_TARGET_PROFILE" in
    lucky-web|lucky-reality|nginx-reality) printf '根域名：%s\n' "${ROOT_DOMAIN:-待填写}" ;;
  esac
  if [[ -n "${REALITY_PUBLIC_ADDRESS:-}" ]]; then printf '保留节点公网地址：%s:443\n' "$REALITY_PUBLIC_ADDRESS"; fi
  if [[ "$SUBSCRIPTION_EXPOSE_MODE_RESOLVED" == direct-ip-https ]]; then echo '订阅继续使用原 IP HTTPS 地址。'; fi
  if [[ "$COMPONENT_FROM_PROFILE" != "$COMPONENT_TARGET_PROFILE" ]]; then
    echo '将调整 443/1443/8443 的服务布局；现有网关/节点连接可能短暂中断。'
  else
    echo '修复或配置受影响服务可能需要重启这些服务。'
  fi
  echo '保留现有身份与配置；只执行上述组件步骤，不执行 SSH 加固、系统升级或 DD。'
  echo '失败后保留候选和备份，可运行 vps-init components resume 重试。'
  echo '备份用于人工恢复；软件包、DNS 和签发的证书不保证可自动撤销。'
}
component_confirm() {
  component_summary
  if [[ "$COMPONENT_FROM_PROFILE" != "$COMPONENT_TARGET_PROFILE" ]]; then
    if [[ "$COMPONENT_YES" == true ]]; then
      [[ "$COMPONENT_ALLOW_TOPOLOGY" == true ]] || die "网络布局变更需额外传入 --allow-topology。"
    else
      local reply
      read -r -p '确认布局变更请输入 CHANGE（其他输入取消）: ' reply || return 10
      [[ "$reply" == CHANGE ]] || return 10
    fi
  fi
  if [[ "$COMPONENT_YES" != true ]]; then
    wizard_yesno '确认执行此组件计划？' n || return 10
  fi
}
component_prepare_candidate() {
  local candidate="$1" old_subscription="$ENABLE_SUBSCRIPTION_RESOLVED" old_mode="$SUBSCRIPTION_EXPOSE_MODE_RESOLVED"
  atomic_config_copy "$DEFAULT_CFG" "$candidate"
  component_config_set "$candidate" PROFILE "$COMPONENT_TARGET_PROFILE"
  case "$COMPONENT_ID" in
    docker)
      if [[ -n "$COMPONENT_SOURCE" ]]; then DOCKER_INSTALL_SOURCE="$COMPONENT_SOURCE"
      elif [[ "$COMPONENT_YES" != true && "$COMPONENT_ACTION" == add ]]; then
        W_ENABLE_DOCKER=true
        wizard_select_docker_install_source
        DOCKER_INSTALL_SOURCE="$W_DOCKER_INSTALL_SOURCE"
      fi
      component_config_set "$candidate" ENABLE_DOCKER true
      component_config_set "$candidate" DOCKER_INSTALL_SOURCE "$DOCKER_INSTALL_SOURCE"
      ;;
    subscription)
      component_config_set "$candidate" ENABLE_SUBSCRIPTION true
      if [[ "$old_mode" == none ]]; then component_config_set "$candidate" SUBSCRIPTION_EXPOSE_MODE auto; fi
      ;;
    cf-ws) component_config_set "$candidate" ENABLE_CF_WS true ;;
  esac
  if profile_has_xui && [[ "$PROFILE" != "$COMPONENT_TARGET_PROFILE" ]]; then
    component_config_set "$candidate" ENABLE_SUBSCRIPTION "$old_subscription"
    # Keep IP subscription URLs. Domain gateways can change backend without changing URL.
    if [[ "$old_mode" == direct-ip-https ]]; then
      component_config_set "$candidate" SUBSCRIPTION_EXPOSE_MODE direct-ip-https
    elif [[ "$old_mode" == nginx-https || "$old_mode" == lucky-https ]]; then
      component_config_set "$candidate" SUBSCRIPTION_EXPOSE_MODE auto
    fi
    component_config_set "$candidate" REALITY_PUBLIC_ADDRESS "${REALITY_PUBLIC_ADDRESS:-${NODE_DOMAIN:-$SERVER_IP}}"
  fi
  local next_profile="$COMPONENT_TARGET_PROFILE"
  PROFILE="$next_profile"
  if profile_has_domain && [[ -z "$ROOT_DOMAIN" ]]; then
    [[ "$COMPONENT_YES" != true ]] || die "缺少 ROOT_DOMAIN；请先编辑配置填写域名，或使用交互模式。"
    ROOT_DOMAIN="$(wizard_prompt_default '根域名（已有 Cloudflare Zone，例如 example.com）' '')"
    component_config_set "$candidate" ROOT_DOMAIN "$ROOT_DOMAIN"
  fi
  load_config "$candidate"
  validate_config
}
component_check_ownership() {
  # Check only installers this plan will invoke, against the ORIGINAL config.
  local step id
  for step in "${COMPONENT_STEPS[@]}"; do
    case "$step" in module_xui) id=reality ;; module_lucky) id=lucky ;; module_nginx) id=nginx ;; optional_docker) id=docker ;; *) continue ;; esac
    if ! component_enabled "$id" && ! component_previously_managed "$id" && component_present "$id"; then
      [[ -f "$COMPONENT_OP/started-$step" ]] || die "检测到非项目管理的 ${id}，拒绝自动接管；请先人工处理。"
    fi
  done
}
component_port_owned() {
  local PROFILE="$COMPONENT_FROM_PROFILE" id="$1" step
  component_enabled "$id" && return 0
  case "$id" in reality) step=module_xui ;; lucky) step=module_lucky ;; nginx) step=module_nginx ;; *) return 1 ;; esac
  [[ -f "$COMPONENT_OP/started-$step" ]]
}
component_check_ports() {
  [[ "$COMPONENT_ID" != docker ]] || return 0
  local port owners listener owner allowed names landing_pid
  for port in 80 443 1443 8443 8444 16601 18080; do
    # Only inspect ports touched by this plan.
    case "$port" in
      80|443) [[ " ${COMPONENT_STEPS[*]} " == *' module_reality '* || " ${COMPONENT_STEPS[*]} " == *' module_nginx '* || " ${COMPONENT_STEPS[*]} " == *' module_lucky '* ]] || continue ;;
      1443) [[ " ${COMPONENT_STEPS[*]} " == *' module_reality '* && "$COMPONENT_TARGET_PROFILE" != reality-only ]] || continue ;;
      8443) [[ " ${COMPONENT_STEPS[*]} " == *' module_nginx '* ]] || continue ;;
      8444) [[ " ${COMPONENT_STEPS[*]} " == *' optional_cf_ws '* ]] || continue ;;
      16601|18080) [[ " ${COMPONENT_STEPS[*]} " == *' module_lucky '* ]] || continue ;;
    esac
    port_in_use "$port" || continue
    # A managed process may have unrelated user-created inbounds. The old
    # reality-only profile never owned :1443, even if Xray is its listener.
    if [[ "$port" == 1443 && "$COMPONENT_FROM_PROFILE" == reality-only && ! -f "$COMPONENT_OP/started-module_reality" ]]; then
      die "TCP 1443 已被占用，原 Reality 独占方案不拥有该端口；请先处理冲突。"
    fi
    owners="$(ss -H -ltnp "sport = :$port" 2>/dev/null)"
    [[ -n "$owners" ]] || die "无法确定 TCP $port 的监听进程，已停止。"
    while IFS= read -r listener; do
      names="$(grep -oE '"[^"]+"' <<<"$listener" | tr -d '"' || true)"
      [[ -n "$names" ]] || die "无法确定 TCP $port 的监听进程，已停止。"
      while IFS= read -r owner; do
        allowed=false
        case "$owner" in
          nginx) if component_port_owned nginx; then allowed=true; fi ;;
          lucky) if component_port_owned lucky; then allowed=true; fi ;;
          xray*|x-ui) if component_port_owned reality; then allowed=true; fi ;;
          python3)
            if [[ "$port" == 18080 ]] && component_port_owned lucky; then
              landing_pid="$(systemctl show -p MainPID --value vps-init-landing)"
              if [[ "$landing_pid" =~ ^[1-9][0-9]*$ && "$listener" == *"pid=$landing_pid,"* ]]; then allowed=true; fi
            fi
            ;;
        esac
        [[ "$allowed" == true ]] || die "TCP $port 存在未确认归属的监听进程 ${owner}，请先检查；没有停止该服务。"
      done <<<"$names"
    done <<<"$owners"
  done
}
component_backup_sqlite() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sqlite3
import sys

with sqlite3.connect(Path(sys.argv[1]).resolve().as_uri() + '?mode=ro', uri=True) as src:
    with sqlite3.connect(sys.argv[2]) as dst:
        src.backup(dst)
PY
  chmod 600 "$2"
}
component_backup() {
  mkdir -p "$COMPONENT_OP/backup"
  chmod 700 "$COMPONENT_OP/backup"
  local path
  for path in "$STATE_FILE" "$SECRETS_FILE"; do
    [[ ! -f "$path" ]] || cp -p "$path" "$COMPONENT_OP/backup/$(basename "$path")"
  done
  local -a paths=()
  if [[ "$COMPONENT_ID" == docker ]]; then
    [[ ! -d /etc/docker ]] || paths+=(etc/docker)
    [[ ! -f /etc/apt/sources.list.d/docker.list ]] || paths+=(etc/apt/sources.list.d/docker.list)
  else
    for path in etc/nginx etc/x-ui opt/lucky etc/systemd/system/lucky.service etc/systemd/system/vps-init-landing.service; do
      [[ ! -e "/$path" ]] || paths+=("$path")
    done
  fi
  if (( ${#paths[@]} )); then
    tar -C / --exclude='etc/x-ui/x-ui.db*' -czf "$COMPONENT_OP/backup/services.tar.gz" "${paths[@]}"
  fi
  if [[ "$COMPONENT_ID" != docker && -f /etc/x-ui/x-ui.db ]]; then
    component_backup_sqlite /etc/x-ui/x-ui.db "$COMPONENT_OP/backup/x-ui.db"
  fi
  touch "$COMPONENT_OP/backup-ready"
}
component_firewall() {
  # Add only newly needed TCP rules; do not reconcile/remove other rules here.
  local port
  while read -r port; do
    ufw allow "$port/tcp" comment 'vps-init component' >/dev/null
  done < <(vpsinit_ufw_desired_tcp_ports | sort -nu)
}
component_release_nginx_backend() {
  # Needed only when replacing the managed Nginx HTTPS backend with Lucky.
  # The saved site remains in the operation backup for manual restoration.
  rm -f /etc/nginx/sites-enabled/vps-init
  nginx -t
  systemctl reload nginx
}
component_progress() {
  local status="$1" rc="${2:-0}" tmp
  tmp="$(mktemp "$COMPONENT_OP/.progress.XXXXXX")"
  printf '状态：%s\n阶段：%s\n退出码：%s\n' "$status" "${COMPONENT_STEP:-prepare}" "$rc" > "$tmp"
  mv -f "$tmp" "$COMPONENT_OP/progress"
}
component_exit() {
  local rc="$1"
  if [[ "${COMPONENT_DONE:-false}" != true && -d "${COMPONENT_OP:-/nonexistent}" ]]; then
    component_progress interrupted "$rc"
    log_warn "组件操作未完成；候选、进度与备份：${COMPONENT_OP}。运行 vps-init components resume。"
  fi
}
component_verify() {
  local id
  if [[ "$COMPONENT_ID" == docker ]]; then
    component_healthy docker || die "Docker Engine / Compose 验收失败。"
  else
    # Include the existing services impacted by SNI/backend changes.
    while read -r id; do
      [[ "$id" != docker ]] || continue
      if component_enabled "$id"; then component_healthy "$id" || die "组件验收失败：$id"; fi
    done < <(component_ids)
  fi
}
component_execute() {
  COMPONENT_DONE=false
  trap 'component_exit $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Config unchanged since planning, or already committed just before a crash.
  cmp -s "$DEFAULT_CFG" "$COMPONENT_OP/before.env" || cmp -s "$DEFAULT_CFG" "$COMPONENT_OP/config.env" || die "正式配置已被其他操作修改，请人工核对候选；不会覆盖。"
  load_config "$COMPONENT_OP/before.env"
  component_check_ownership
  # On resume use target capability ownership only after module-start markers exist.
  if [[ -f "$COMPONENT_OP/mutations-started" ]]; then
    load_config "$COMPONENT_OP/config.env"
  fi
  component_check_ports
  [[ -f "$COMPONENT_OP/backup-ready" ]] || component_backup
  load_config "$COMPONENT_OP/config.env"
  validate_config
  touch "$COMPONENT_OP/mutations-started"
  local step
  for step in "${COMPONENT_STEPS[@]}"; do
    COMPONENT_STEP="$step"
    component_progress running
    touch "$COMPONENT_OP/started-$step"
    log_info "组件步骤：$step"
    "$step"
    component_progress completed
  done
  COMPONENT_STEP=verify
  component_progress running
  component_verify
  # Editors outside this program may ignore deploy.lock; check again at commit.
  cmp -s "$DEFAULT_CFG" "$COMPONENT_OP/before.env" || cmp -s "$DEFAULT_CFG" "$COMPONENT_OP/config.env" || die "执行期间正式配置发生变化，拒绝覆盖；请人工核对后恢复。"
  # These values describe the verified configuration, never a half-applied plan.
  persist_config "$COMPONENT_OP/config.env"
  state_set INITIAL_PROFILE "${INITIAL_PROFILE:-$COMPONENT_FROM_PROFILE}"
  state_set DEPLOYED_PROFILE "$PROFILE"
  state_set DEPLOYED_VERSION "$VPSINIT_VERSION"
  state_set DEPLOYMENT_VERIFIED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  COMPONENT_STEP=complete
  component_progress verified
  mkdir -p "$STATE_DIR/component-history"
  chmod 700 "$STATE_DIR/component-history"
  local archive
  archive="$(mktemp -d "$STATE_DIR/component-history/operation.XXXXXX")"
  rmdir "$archive"
  mv "$COMPONENT_OP" "$archive"
  COMPONENT_DONE=true
  log_ok "组件变更已验收并保存；操作记录及备份：$archive"
  if [[ "$COMPONENT_ID" != docker ]]; then show_info_summary "$DEFAULT_CFG"; fi
  echo '下一步：vps-init components status；管理凭据：vps-init secrets'
}
component_change() {
  COMPONENT_ACTION="$1"; COMPONENT_ID="$2"
  component_lock
  COMPONENT_OP="$STATE_DIR/component-operation"
  [[ ! -d "$COMPONENT_OP" ]] || die "存在未完成的组件操作，请运行 vps-init components resume。"
  component_load_current
  COMPONENT_FROM_PROFILE="$PROFILE"
  component_plan "$COMPONENT_ACTION" "$COMPONENT_ID"
  if [[ "$COMPONENT_ACTION" == add ]] && component_enabled "$COMPONENT_ID"; then
    log_info '该组件已启用；如需修复，请选择修复组件。'
    return 0
  fi
  COMPONENT_DRAFT="$(mktemp -d "$STATE_DIR/.component-draft.XXXXXX")"
  local draft="$COMPONENT_DRAFT"
  chmod 700 "$draft"
  trap 'rm -rf -- "$COMPONENT_DRAFT"' EXIT
  atomic_config_copy "$DEFAULT_CFG" "$draft/before.env"
  component_prepare_candidate "$draft/config.env"
  component_confirm
  # Store only validated action/id; rebuild steps from the original config on resume.
  printf 'COMPONENT_ACTION=%q\nCOMPONENT_ID=%q\n' "$COMPONENT_ACTION" "$COMPONENT_ID" > "$draft/request.env"
  chmod 600 "$draft/request.env"
  mv "$draft" "$COMPONENT_OP"
  trap - EXIT
  component_execute
}
component_resume() {
  component_lock
  COMPONENT_OP="$STATE_DIR/component-operation"
  [[ -f "$COMPONENT_OP/request.env" && -f "$COMPONENT_OP/before.env" && -f "$COMPONENT_OP/config.env" ]] || die "没有完整的组件恢复记录。"
  state_load
  # shellcheck disable=SC1091
  source "$COMPONENT_OP/request.env"
  load_config "$COMPONENT_OP/before.env"
  COMPONENT_FROM_PROFILE="$PROFILE"
  component_plan "$COMPONENT_ACTION" "$COMPONENT_ID"
  local expected_profile="$COMPONENT_TARGET_PROFILE"
  if [[ -n "$COMPONENT_SOURCE" ]]; then
    [[ "$COMPONENT_ID" == docker ]] || die "--source 只适用于 Docker 操作。"
    component_config_set "$COMPONENT_OP/config.env" DOCKER_INSTALL_SOURCE "$COMPONENT_SOURCE"
  fi
  load_config "$COMPONENT_OP/config.env"
  [[ "$PROFILE" == "$expected_profile" ]] || die "恢复配置的 Profile 与原计划不符。"
  validate_config
  component_confirm
  component_execute
}
component_available() {
  component_load_current
  local action="$1" id
  while read -r id; do
    if [[ "$action" == repair ]]; then
      component_enabled "$id" || continue
    else
      component_enabled "$id" && continue
      case "$id" in
        nginx|subscription) profile_has_xui || continue ;;
        cf-ws) profile_has_xui && profile_has_domain && is_true "$ENABLE_SUBSCRIPTION_RESOLVED" || continue ;;
      esac
    fi
    printf '%s|%s\n' "$id" "$(component_label "$id")"
  done < <(component_ids)
}
component_cancel() {
  component_lock
  local pending="$STATE_DIR/component-operation" archive
  [[ -d "$pending" ]] || die "没有待取消的组件操作。"
  [[ ! -f "$pending/mutations-started" ]] || die "操作已经开始修改系统，不能取消记录；请运行 components resume。"
  if [[ "$COMPONENT_YES" != true ]]; then
    wizard_yesno '归档未开始执行的计划并解除阻塞？' n || return 10
  fi
  mkdir -p "$STATE_DIR/component-history"
  chmod 700 "$STATE_DIR/component-history"
  archive="$(mktemp -d "$STATE_DIR/component-history/cancelled.XXXXXX")"
  rmdir "$archive"
  mv "$pending" "$archive"
  log_ok "未执行的计划已取消，记录保留在：$archive"
}
components_menu() {
  [[ -t 0 ]] || die "组件菜单需要 TTY；也可使用 components status / plan / add / repair / resume。"
  local action id choice rc rows label
  while true; do
    "$ROOT_DIR/vps-init" components status || true
    action="$(wizard_select '组件管理' '增装组件' '修复已启用组件' '继续失败的组件操作' '取消尚未执行的组件计划')" || return 0
    if [[ "$action" == 3 ]]; then
      "$ROOT_DIR/vps-init" components resume || true
    elif [[ "$action" == 4 ]]; then
      "$ROOT_DIR/vps-init" components cancel || true
    else
      local -a ids=() labels=()
      if [[ "$action" == 1 ]]; then action=add; else action=repair; fi
      rows="$(component_available "$action")" || continue
      if [[ -z "$rows" ]]; then echo '当前没有可执行此操作的组件。'; continue; fi
      while IFS='|' read -r id label; do ids+=("$id"); labels+=("$label"); done <<<"$rows"
      choice="$(wizard_select '选择组件（依赖自动处理）' "${labels[@]}")" || continue
      rc=0
      "$ROOT_DIR/vps-init" components "$action" "${ids[choice-1]}" || rc=$?
      if (( rc != 0 && rc != 10 )); then echo '操作失败，可查看进度并选择继续；已保存的配置不必重新填写。'; fi
    fi
    read -r -p '按 Enter 返回组件菜单...' _ || return 0
  done
}
component_command() {
  local action="${1:-menu}" id="${2:-}"
  COMPONENT_YES=false; COMPONENT_ALLOW_TOPOLOGY=false; COMPONENT_SOURCE=""
  case "$action" in
    menu) components_menu; return ;;
    status) component_status; return ;;
    plan|add|repair) [[ -n "$id" ]] || die "请指定组件：docker/reality/lucky/nginx/subscription/cf-ws"; shift 2 ;;
    resume|cancel) shift ;;
    *) die "组件命令：components [status|plan|add|repair|resume|cancel] [组件]" ;;
  esac
  while (( $# )); do
    case "$1" in
      --yes) COMPONENT_YES=true ;;
      --allow-topology) COMPONENT_ALLOW_TOPOLOGY=true ;;
      --source=official|--source=aliyun) COMPONENT_SOURCE="${1#*=}" ;;
      *) die "未知组件选项：$1" ;;
    esac
    shift
  done
  if [[ "$action" == plan ]]; then
    component_load_current
    COMPONENT_ACTION=add; COMPONENT_ID="$id"; COMPONENT_FROM_PROFILE="$PROFILE"
    component_plan add "$id"
    component_summary
  elif [[ "$action" == cancel ]]; then component_cancel
  elif [[ "$action" == resume ]]; then component_resume
  else component_change "$action" "$id"; fi
}
