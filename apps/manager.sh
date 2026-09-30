#!/usr/bin/env bash

source "$ROOT_DIR/apps/common.sh"
source "$ROOT_DIR/apps/gateway/nginx.sh"
source "$ROOT_DIR/apps/qinglong/app.sh"

app_docker_status() {
  if command_exists docker && docker info >/dev/null 2>&1; then
    echo "Docker Engine：已安装 / active"
  elif command_exists docker; then
    echo "Docker Engine：已安装 / inactive"
  else
    echo "Docker Engine：未安装"
  fi
}

app_qinglong_label() {
  if qinglong_installed; then
    printf "青龙面板（已安装）"
  else
    printf "青龙面板（未安装）"
  fi
}

app_qinglong_menu() {
  local n domain default_domain=""
  while true; do
    echo
    echo "=============== 青龙面板 ==============="
    echo "  1. 安装 / 修复"
    echo "  2. 查看状态"
    echo "  3. 运行验收"
    echo "  4. 更新"
    echo "  5. 卸载（保留数据）"
    echo "  0. 返回"
    read -r -p "请选择 [0-5]: " n
    case "$n" in
      1)
        app_core_context
        if [[ "$PROFILE" == "nginx-reality" ]]; then
          default_domain="ql.${ROOT_DOMAIN}"
          read -r -p "应用域名 [${default_domain}]: " domain
          domain="${domain:-$default_domain}"
          app_validate_domain "$domain" || { echo "域名格式无效。"; continue; }
        else
          echo "当前 Profile=${PROFILE}。v1.3.0 MVP 的自动 HTTPS Gateway 先支持 nginx-reality。"
          if ! wizard_yesno "仍然只安装到本机 127.0.0.1，不配置公网反代？" n; then continue; fi
          domain=""
        fi
        qinglong_install "$domain"
        ;;
      2) qinglong_status ;;
      3) qinglong_verify && echo "✅ 青龙验收通过" || echo "❌ 青龙验收失败" ;;
      4) qinglong_update ;;
      5)
        if wizard_yesno "确认卸载青龙容器和反向代理？数据目录会保留。" n; then qinglong_remove; fi
        ;;
      0) return 0 ;;
      *) echo "输入无效。" ;;
    esac
  done
}

app_center_menu() {
  require_root
  [[ -t 0 ]] || die "应用中心需要交互式终端。"
  local n
  while true; do
    echo
    echo "============================================================"
    echo "                     应用中心"
    echo "============================================================"
    app_docker_status
    echo
    echo "  1. $(app_qinglong_label)"
    echo "  2. Docker Engine（运行环境）"
    echo "  0. 返回"
    read -r -p "请选择 [0-2]: " n
    case "$n" in
      1) app_qinglong_menu ;;
      2)
        if command_exists docker; then
          docker version --format "Docker Engine：{{.Server.Version}}" 2>/dev/null || true
          docker compose version 2>/dev/null || true
        else
          if wizard_yesno "Docker 未安装，是否现在安装？" y; then ensure_docker_runtime; fi
        fi
        ;;
      0) return 0 ;;
      *) echo "输入无效。" ;;
    esac
  done
}

app_command() {
  local id="${1:-}" action="${2:-status}" arg="${3:-}"
  case "$id" in
    ""|menu) app_center_menu ;;
    qinglong|ql)
      case "$action" in
        install) qinglong_install "$arg" ;;
        status) qinglong_status ;;
        verify) qinglong_verify ;;
        update) qinglong_update ;;
        remove) qinglong_remove ;;
        *) die "用法：vps-init app qinglong [install|status|verify|update|remove] [domain]" ;;
      esac
      ;;
    *) die "未知应用：$id" ;;
  esac
}
