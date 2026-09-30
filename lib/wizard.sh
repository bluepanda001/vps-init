#!/usr/bin/env bash
set -Eeuo pipefail

wizard_banner() {
  local ver="unknown"
  [[ -r "$ROOT_DIR/VERSION" ]] && ver="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
  cat <<EOF2
============================================================
                     VPS Init ${ver}
============================================================
用途：用于 VPS 自动化初始化、配置与验收。

推荐在全新 Ubuntu 24.04 LTS VPS 上运行。
EOF2
}

wizard_select() {
  local prompt="$1"; shift
  local reply
  while true; do
    echo "$prompt" >&2
    local i=1 opt
    for opt in "$@"; do printf '  %d. %s\n' "$i" "$opt" >&2; i=$((i+1)); done
    read -r -p "请选择 [1-$#]: " reply
    [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= $# )) && { printf '%s\n' "$reply"; return 0; }
    echo "输入无效，请重新选择。" >&2
  done
}

wizard_yesno() {
  local prompt="$1" default="${2:-y}" reply
  if [[ "$default" == y ]]; then
    read -r -p "$prompt [Y/n]: " reply; reply="${reply:-y}"
  else
    read -r -p "$prompt [y/N]: " reply; reply="${reply:-n}"
  fi
  [[ "$reply" =~ ^[Yy]$ ]]
}

wizard_prompt_default() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply
    printf '%s\n' "${reply:-$default}"
  else
    read -r -p "$prompt: " reply
    printf '%s\n' "$reply"
  fi
}


wizard_prompt_secret() {
  local prompt="$1" reply
  read -r -s -p "$prompt: " reply
  echo >&2
  printf '%s\n' "$reply"
}

wizard_validate_admin_username() {
  local v="$1"
  [[ -z "$v" || ( "$v" != *[[:space:]]* && ${#v} -ge 3 && ${#v} -le 64 ) ]]
}

wizard_collect_admin_credentials() {
  W_XUI_USERNAME_INPUT=""
  W_XUI_PASSWORD_INPUT=""
  W_LUCKY_USERNAME_INPUT=""
  W_LUCKY_PASSWORD_INPUT=""
  [[ "$W_PROFILE" != "base-only" ]] || return 0

  echo
  echo "面板管理账号（不会写入普通 config.env；只保存在 root-only state/secrets）："
  local u p p2
  while true; do
    if [[ -n "${XUI_USERNAME:-}" ]]; then
      read -r -p "3x-ui 用户名（留空=保持当前 ${XUI_USERNAME}）: " u
    else
      read -r -p "3x-ui 用户名（留空=自动随机生成）: " u
    fi
    wizard_validate_admin_username "$u" && break
    echo "用户名需为 3-64 个非空白字符，请重新输入。"
  done
  while true; do
    p="$(wizard_prompt_secret "3x-ui 密码（留空=保持当前/新部署自动随机生成）")"
    [[ -z "$p" || ${#p} -ge 8 ]] || { echo "密码至少 8 个字符。"; continue; }
    if [[ -n "$p" ]]; then
      p2="$(wizard_prompt_secret "再次输入 3x-ui 密码")"
      [[ "$p" == "$p2" ]] || { echo "两次密码不一致，请重新输入。"; continue; }
    fi
    break
  done
  W_XUI_USERNAME_INPUT="$u"
  W_XUI_PASSWORD_INPUT="$p"

  if [[ "$W_PROFILE" == "lucky-reality" ]]; then
    echo
    while true; do
      if [[ -n "${LUCKY_USERNAME:-}" ]]; then
        read -r -p "Lucky 用户名（留空=保持当前 ${LUCKY_USERNAME}）: " u
      else
        read -r -p "Lucky 用户名（留空=自动随机生成）: " u
      fi
      wizard_validate_admin_username "$u" && break
      echo "用户名需为 3-64 个非空白字符，请重新输入。"
    done
    while true; do
      p="$(wizard_prompt_secret "Lucky 密码（留空=保持当前/新部署自动随机生成）")"
      [[ -z "$p" || ${#p} -ge 8 ]] || { echo "密码至少 8 个字符。"; continue; }
      if [[ -n "$p" ]]; then
        p2="$(wizard_prompt_secret "再次输入 Lucky 密码")"
        [[ "$p" == "$p2" ]] || { echo "两次密码不一致，请重新输入。"; continue; }
      fi
      break
    done
    W_LUCKY_USERNAME_INPUT="$u"
    W_LUCKY_PASSWORD_INPUT="$p"
  fi
}

wizard_detect_ssh_port() {
  local p=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    p="$(awk '{print $4}' <<<"$SSH_CONNECTION" 2>/dev/null || true)"
  fi
  if ! [[ "$p" =~ ^[0-9]+$ ]] || ((p < 1 || p > 65535)); then
    p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  fi
  [[ "$p" =~ ^[0-9]+$ ]] || p=22
  printf '%s\n' "$p"
}

wizard_existing_ed25519_keys() {
  [[ -r /root/.ssh/authorized_keys ]] || return 1
  # Preserve every unique plain ED25519 key, but emit vps-main first so the
  # unified key is guaranteed to survive an optional DD reinstall even when an
  # older emergency key appears earlier in authorized_keys.
  awk '
    $1=="ssh-ed25519" && !seen[$0]++ {
      if ($NF=="vps-main") main[++m]=$0
      else other[++n]=$0
    }
    END {
      for (i=1; i<=m; i++) print main[i]
      for (i=1; i<=n; i++) print other[i]
    }
  ' /root/.ssh/authorized_keys
}

wizard_existing_ed25519_key() {
  local vps_main
  vps_main="$(wizard_existing_vps_main_key || true)"
  if [[ -n "$vps_main" ]]; then
    printf '%s\n' "$vps_main"
    return 0
  fi
  [[ -r /root/.ssh/authorized_keys ]] || return 1
  awk '$1=="ssh-ed25519" {print; exit}' /root/.ssh/authorized_keys
}

wizard_existing_vps_main_key() {
  [[ -r /root/.ssh/authorized_keys ]] || return 1
  awk '$1=="ssh-ed25519" && $NF=="vps-main" {print; exit}' /root/.ssh/authorized_keys
}

wizard_offer_reinstall() {
  # Destructive reinstall is pinned to a reviewed upstream commit.
  local reinstall_repo="bin456789/reinstall"
  local reinstall_commit="2bcbc96100fe733bf9a16d609f799246f62666e5"
  local choice virt confirm_word script current_port key
  local -a cmd existing_keys

  echo
  choice="$(wizard_select "系统准备：" \
    "不重装，直接初始化当前系统（推荐：系统已经是干净 Ubuntu 24.04 时选这个）" \
    "一键 DD / 重装 Ubuntu 24.04 Minimal（bin456789/reinstall）" \
    "返回 / 取消本次向导")"

  case "$choice" in
    1) return 0 ;;
    3) return 12 ;;
  esac

  echo
  echo "============================================================"
  echo "                 危险操作：整盘重装"
  echo "============================================================"
  echo "将调用我们之前用过的：$reinstall_repo"
  echo "固定上游提交：$reinstall_commit"
  echo
  echo "目标系统：Ubuntu 24.04 Minimal"
  echo "警告：重装会清除主硬盘全部数据，包括所有分区。"
  echo "当前 vps-init、3x-ui、Docker、网站、证书等磁盘数据都会被删除。"
  echo "重启后 SSH 会断开；系统安装完成后，需要重新连接并再次运行 vps-init 一键命令。"
  echo

  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "$virt" in
    openvz|lxc|lxc-libvirt)
      die "检测到 $virt。bin456789/reinstall 官方明确不支持 OpenVZ/LXC；不会继续 DD。"
      ;;
  esac

  read -r -p "确认清空整盘并重装 Ubuntu 24.04 Minimal，请输入大写 DD： " confirm_word
  [[ "$confirm_word" == "DD" ]] || { echo "未输入 DD，已取消重装，返回安装向导。"; return 0; }

  script="/root/reinstall.sh"
  curl -fL --retry 3 --connect-timeout 10 --max-time 60     -o "$script"     "https://raw.githubusercontent.com/$reinstall_repo/$reinstall_commit/reinstall.sh"
  chmod 700 "$script"

  current_port="$(wizard_detect_ssh_port)"
  mapfile -t existing_keys < <(wizard_existing_ed25519_keys || true)

  cmd=(bash "$script" ubuntu 24.04 --minimal --user root)
  if (( ${#existing_keys[@]} > 0 )); then
    echo
    echo "检测到当前 root 的 ${#existing_keys[@]} 把 ED25519 公钥。DD 后会全部保留；vps-main 会优先传入。"
    # The pinned bin456789/reinstall commit appends repeated --ssh-key values
    # into the target authorized_keys, so pass every unique ED25519 key.
    for key in "${existing_keys[@]}"; do
      cmd+=(--ssh-key "$key")
    done
    cmd+=(--ssh-port "$current_port")
  else
    echo
    echo "当前没有检测到 root 的 ED25519 authorized key。"
    echo "上游 reinstall 脚本会在需要时要求你设置重装后的 SSH 登录凭据。"
  fi

  echo
  echo "开始准备一键重装（此阶段只写入下一次启动的重装环境；真正清盘在 reboot 后开始）..."
  "${cmd[@]}"

  echo
  echo "============================================================"
  echo "Ubuntu 24.04 Minimal 重装已经准备好。"
  echo
  echo "在重启前如果改变主意，可运行："
  echo "  bash /root/reinstall.sh reset"
  echo
  echo "重启后开始真正重装；SSH 会断开。"
  echo "系统装好并重新 SSH 登录后，再执行："
  echo
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/bluepanda001/vps-init/main/install.sh)"
  echo
  echo "第二次进入向导时选择：不重装，直接初始化当前系统。"
  echo "============================================================"
  echo

  if wizard_yesno "现在立即 reboot 开始重装？" y; then
    sync
    reboot
    # reboot(8) may return before systemd actually tears down this SSH
    # session. Propagate a special status so a parent menu does not print
    # a misleading "按 Enter 返回菜单" while the machine is going down.
    return 42
  fi

  echo "已暂缓 reboot。准备好后手动执行：reboot"
  return 12
}

wizard_shell_quote_value() {
  # config.env is sourced by bash; %q safely represents arbitrary single-line values.
  printf '%q' "$1"
}

wizard_write_config() {
  local dst="$1"
  umask 077
  cat > "$dst" <<EOF2
# Generated by VPS Init interactive wizard.
# You may edit this file and rerun: vps-init apply "$dst"
PROFILE=$(wizard_shell_quote_value "$W_PROFILE")
PROVIDER=$(wizard_shell_quote_value "$W_PROVIDER")
SERVER_NAME=$(wizard_shell_quote_value "$W_SERVER_NAME")
SSH_PORT=$(wizard_shell_quote_value "$W_SSH_PORT")
SSH_PUBLIC_KEY=$(wizard_shell_quote_value "$W_SSH_PUBLIC_KEY")
SSH_IDENTITY_HINT=$(wizard_shell_quote_value "$W_SSH_IDENTITY_HINT")
ROOT_DOMAIN=$(wizard_shell_quote_value "$W_ROOT_DOMAIN")
DNS_PROVIDER="cloudflare"
LE_EMAIL=$(wizard_shell_quote_value "$W_LE_EMAIL")
PANEL_DOMAIN_OVERRIDE=""
NODE_DOMAIN_OVERRIDE=""
REALITY_TARGET_MODE=$(wizard_shell_quote_value "$W_REALITY_TARGET_MODE")
REALITY_TARGET=$(wizard_shell_quote_value "$W_REALITY_TARGET")
REALITY_CANDIDATES="dl.google.com,www.apple.com,www.google.com,github.io"
ENABLE_SUBSCRIPTION="auto"
SUBSCRIPTION_EXPOSE_MODE="auto"
SUBSCRIPTION_PORT=$(wizard_shell_quote_value "$W_SUBSCRIPTION_PORT")
XUI_PANEL_URI_PATH=$(wizard_shell_quote_value "$W_PANEL_PATH")
XUI_SUB_URI_PATH=$(wizard_shell_quote_value "$W_SUB_PATH")
ENABLE_DOCKER=$(wizard_shell_quote_value "$W_ENABLE_DOCKER")
ENABLE_CF_WS=$(wizard_shell_quote_value "$W_ENABLE_CF_WS")
ENABLE_CF_PREFERRED="false"
ENABLE_CLOUDFLARESUB="false"
EOF2
  chmod 600 "$dst"
}

wizard_collect_ssh_key() {
  W_SSH_IDENTITY_HINT="vps-main-ed25519"
  local existing_vps_main existing_any choice pasted
  existing_vps_main="$(wizard_existing_vps_main_key || true)"
  existing_any="$(wizard_existing_ed25519_key || true)"

  if [[ -n "$existing_vps_main" ]]; then
    echo
    echo "检测到 root 已经安装统一 vps-main 公钥："
    ssh-keygen -lf <(printf '%s\n' "$existing_vps_main") 2>/dev/null || true
    if wizard_yesno "继续使用这把 vps-main？" y; then
      W_SSH_PUBLIC_KEY="$existing_vps_main"
      return 0
    fi
  fi

  local -a options=(
    "粘贴现有 vps-main 的 ssh-ed25519 公钥（推荐：所有普通 VPS 共用）"
    "第一次创建 vps-main：显示 Windows PowerShell 命令，然后回来粘贴"
  )
  if [[ -n "$existing_any" && "$existing_any" != "$existing_vps_main" ]]; then
    options+=("使用服务器当前已有 ED25519 公钥（兼容旧配置，不推荐作为统一方案）")
  fi

  choice="$(wizard_select "SSH 公钥（标准方案：一把 vps-main + 每台 VPS 一个 Netcatty Identity）：" "${options[@]}")"

  if [[ "$choice" == 2 ]]; then
    cat <<'EOF2'

请在你自己的 Windows PowerShell 另开窗口执行：

ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\vps-main-ed25519" -C "vps-main"
Get-Content "$env:USERPROFILE\.ssh\vps-main-ed25519.pub" | Set-Clipboard

生成后，把无 .pub 后缀的私钥导入 Netcatty Keychain，Label 固定为 vps-main。
私钥只保存在 Windows / Netcatty Keychain，绝对不要上传到 VPS、GitHub 或聊天。
EOF2
  elif [[ "$choice" == 3 && -n "$existing_any" ]]; then
    W_SSH_PUBLIC_KEY="$existing_any"
    W_SSH_IDENTITY_HINT=""
    return 0
  fi

  while true; do
    read -r -p "现在粘贴完整 ssh-ed25519 公钥: " pasted
    if [[ "$pasted" == ssh-ed25519\ * ]]; then
      local tmp
      tmp="$(mktemp)"
      printf '%s\n' "$pasted" > "$tmp"
      if ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        W_SSH_PUBLIC_KEY="$pasted"
        return 0
      fi
      rm -f "$tmp"
    fi
    echo "这不是可解析的 ssh-ed25519 公钥，请重新粘贴。"
  done
}

wizard_collect() {
  require_root
  [[ -t 0 ]] || die "交互向导需要 TTY。"
  if ! command_exists curl; then
    wait_apt_lock 300
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates
  fi
  wizard_banner
  echo

  # First decision: optionally reinstall to a known-clean Ubuntu before
  # collecting any VPS Init settings. Major choice screens include an explicit
  # way back so an accidental number does not force the rest of the wizard.
  local prep_rc=0 mode_choice profile_choice current_port custom
  while true; do
    prep_rc=0
    wizard_offer_reinstall || prep_rc=$?
    (( prep_rc == 42 )) && return 42
    (( prep_rc == 12 )) && return 12

    mode_choice="$(wizard_select "安装方式：" \
      "快速安装（推荐：沿用当前 SSH 端口，只问必要项目）" \
      "自定义安装（可改端口/路径/订阅端口/Docker 等）" \
      "返回系统准备")"
    [[ "$mode_choice" == 3 ]] && continue
    custom="false"
    [[ "$mode_choice" == 2 ]] && custom="true"

    profile_choice="$(wizard_select "请选择部署模式：" \
      "Base Only - 系统初始化/安全/BBR/Swap，不安装 3x-ui" \
      "Reality Only - 3x-ui + Reality + IP HTTPS 订阅，不需要域名" \
      "Lucky + Reality - 推荐：图形化 Web Gateway + Reality，共用公网 443，需要 Cloudflare 域名" \
      "Nginx + Reality - 轻量/高级：纯 Nginx 配置 + Reality，需要 Cloudflare 域名" \
      "返回安装方式")"
    [[ "$profile_choice" == 5 ]] && continue
    case "$profile_choice" in
      1) W_PROFILE="base-only" ;;
      2) W_PROFILE="reality-only" ;;
      3) W_PROFILE="lucky-reality" ;;
      4) W_PROFILE="nginx-reality" ;;
    esac
    break
  done
  W_ALLOW_PROFILE_SWITCH="0"
  state_load
  if [[ -n "${DEPLOYED_PROFILE:-}" && "$DEPLOYED_PROFILE" != "$W_PROFILE" ]]; then
    echo
    echo "这台 VPS 当前已部署 Profile=${DEPLOYED_PROFILE}，准备切换为 ${W_PROFILE}。"
    echo "迁移只会停用/调整 vps-init 自己管理的 Nginx/Lucky/Xray 拓扑，不会清盘。"
    if wizard_yesno "确认执行 Profile 迁移？" n; then
      W_ALLOW_PROFILE_SWITCH="1"
    else
      echo "已取消 Profile 迁移。"
      return 12
    fi
  fi

  W_SERVER_IP="$(get_public_ipv4 || true)"
  [[ -n "$W_SERVER_IP" ]] || die "无法检测公网 IPv4。"
  echo
  echo "检测到公网 IPv4：$W_SERVER_IP"

  W_PROVIDER="$(wizard_prompt_default "VPS 服务商（用于名称/报告，例如 racknerd、vmiss）" "vps")"
  W_SERVER_NAME="$(wizard_prompt_default "这台 VPS 的名称（同时建议作为 Netcatty Identity 名称）" "${W_PROVIDER}-${W_SERVER_IP}")"
  current_port="$(wizard_detect_ssh_port)"
  if [[ "$custom" == true ]]; then
    W_SSH_PORT="$(wizard_prompt_default "SSH 端口" "$current_port")"
  else
    W_SSH_PORT="$current_port"
    echo "SSH 端口：$W_SSH_PORT（沿用当前连接）"
  fi
  [[ "$W_SSH_PORT" =~ ^[0-9]+$ ]] && ((W_SSH_PORT>=1 && W_SSH_PORT<=65535)) || die "SSH 端口无效。"
  wizard_collect_ssh_key
  wizard_collect_admin_credentials

  W_ROOT_DOMAIN=""; W_LE_EMAIL=""
  if [[ "$W_PROFILE" == "nginx-reality" || "$W_PROFILE" == "lucky-reality" ]]; then
    echo
    while [[ -z "$W_ROOT_DOMAIN" ]]; do
      W_ROOT_DOMAIN="$(wizard_prompt_default "Cloudflare 根域名（例如 example.com）" "")"
      [[ "$W_ROOT_DOMAIN" != *://* && "$W_ROOT_DOMAIN" != */* && "$W_ROOT_DOMAIN" == *.* ]] || { echo "请只填写根域名，不要带 https:// 或路径。"; W_ROOT_DOMAIN=""; }
    done
    W_LE_EMAIL="$(wizard_prompt_default "Let's Encrypt 邮箱（可留空）" "")"
  fi

  W_REALITY_TARGET_MODE="auto"; W_REALITY_TARGET=""
  if [[ "$W_PROFILE" != "base-only" && "$custom" == true ]]; then
    local target_choice
    target_choice="$(wizard_select "Reality Target：" "自动检测并推荐（推荐）" "手动填写")"
    if [[ "$target_choice" == 2 ]]; then
      W_REALITY_TARGET_MODE="manual"
      while [[ -z "$W_REALITY_TARGET" ]]; do W_REALITY_TARGET="$(wizard_prompt_default "Reality Target，例如 dl.google.com:443" "")"; done
    fi
  fi

  W_PANEL_PATH="/zhg/"
  W_SUB_PATH="/zhg/"
  W_SUBSCRIPTION_PORT="2096"
  W_ENABLE_DOCKER="false"
  W_ENABLE_CF_WS="false"
  if [[ "$W_PROFILE" == "nginx-reality" || "$W_PROFILE" == "lucky-reality" ]]; then
    W_ENABLE_CF_WS="true"
    if [[ "$custom" == true ]]; then
      if ! wizard_yesno "同时部署 Cloudflare CDN WS 备用节点（edge.<域名>）？" y; then
        W_ENABLE_CF_WS="false"
      fi
    fi
  fi
  if [[ "$custom" == true && "$W_PROFILE" != "base-only" ]]; then
    W_PANEL_PATH="$(normalize_path "$(wizard_prompt_default "3x-ui 面板 URI Path" "/zhg/")")"
    local sub_input
    sub_input="$(wizard_prompt_default "订阅 URI Path" "/zhg/")"
    W_SUB_PATH="$(normalize_path "$sub_input")"
    W_SUBSCRIPTION_PORT="$(wizard_prompt_default "3x-ui Subscription 内部/直连端口" "2096")"
    [[ "$W_SUBSCRIPTION_PORT" =~ ^[0-9]+$ ]] && ((W_SUBSCRIPTION_PORT>=1 && W_SUBSCRIPTION_PORT<=65535)) || die "订阅端口无效。"
  fi
  if [[ "$custom" == true ]]; then
    if wizard_yesno "同时安装 Docker Engine/Compose？" n; then W_ENABLE_DOCKER="true"; fi
  fi

  echo
  echo "---------------- 部署摘要 ----------------"
  echo "Profile           : $W_PROFILE"
  echo "IPv4              : $W_SERVER_IP"
  echo "SSH Port          : $W_SSH_PORT"
  [[ -n "$W_ROOT_DOMAIN" ]] && echo "Root Domain       : $W_ROOT_DOMAIN"
  if [[ "$W_PROFILE" != "base-only" ]]; then
    echo "Panel URI         : $W_PANEL_PATH"
    echo "Subscription URI  : $W_SUB_PATH"
    echo "Subscription Port : $W_SUBSCRIPTION_PORT"
    echo "Reality Target    : ${W_REALITY_TARGET_MODE}${W_REALITY_TARGET:+ ($W_REALITY_TARGET)}"
    echo "Clash/Mihomo      : ON / Routing ON / Auto Detect ON / (?i)(clash|mihomo)"
    if [[ -n "${W_XUI_USERNAME_INPUT:-}${W_XUI_PASSWORD_INPUT:-}" ]]; then
      echo "3x-ui Credentials : 用户自定义"
    else
      echo "3x-ui Credentials : 保持现有 / 新部署自动生成"
    fi
    if [[ "$W_PROFILE" == "lucky-reality" ]]; then
      if [[ -n "${W_LUCKY_USERNAME_INPUT:-}${W_LUCKY_PASSWORD_INPUT:-}" ]]; then
        echo "Lucky Credentials : 用户自定义"
      else
        echo "Lucky Credentials : 保持现有 / 新部署自动生成"
      fi
    fi
  fi
  echo "Docker            : $W_ENABLE_DOCKER"
  if [[ "$W_PROFILE" == "nginx-reality" || "$W_PROFILE" == "lucky-reality" ]]; then
    echo "Cloudflare CDN WS : $W_ENABLE_CF_WS"
  fi
  echo "------------------------------------------"
  wizard_yesno "确认并开始部署？" y || return 10
}

wizard_run() {
  local cfg="${1:-$PERSIST_DIR/config.env}" pending backup="" rc=0 rollback_rc=0 previous_profile=""
  ensure_dir "$(dirname "$cfg")"
  state_load
  previous_profile="${DEPLOYED_PROFILE:-}"
  if [[ -f "$cfg" && -n "$previous_profile" ]]; then
    backup="$(mktemp "$(dirname "$cfg")/.config.env.rollback.XXXXXX")"
    cp -a "$cfg" "$backup"
    chmod 600 "$backup"
  fi

  wizard_collect || { [[ -n "$backup" ]] && rm -f "$backup"; return $?; }

  # Keep the last verified config intact until the candidate deployment passes
  # verification. A failed Profile migration must not leave config.env pointing
  # at a topology that DEPLOYED_PROFILE never accepted.
  pending="$(mktemp "$(dirname "$cfg")/.config.env.pending.XXXXXX")"
  wizard_write_config "$pending"
  log_ok "候选配置已生成；验收通过后才会提交到：$cfg"

  VPSINIT_ALLOW_PROFILE_SWITCH="${W_ALLOW_PROFILE_SWITCH:-0}" \
  VPSINIT_XUI_USERNAME_INPUT="${W_XUI_USERNAME_INPUT:-}" \
  VPSINIT_XUI_PASSWORD_INPUT="${W_XUI_PASSWORD_INPUT:-}" \
  VPSINIT_LUCKY_USERNAME_INPUT="${W_LUCKY_USERNAME_INPUT:-}" \
  VPSINIT_LUCKY_PASSWORD_INPUT="${W_LUCKY_PASSWORD_INPUT:-}" \
    "$ROOT_DIR/vps-init" apply "$pending" || rc=$?
  if (( rc == 0 )); then
    install -m 600 "$pending" "$cfg"
    log_ok "部署与验收通过，配置已提交：$cfg"
  else
    log_warn "部署未通过，原有已验证配置未被候选配置覆盖。"
    if [[ -n "$backup" && -n "$previous_profile" ]]; then
      log_warn "尝试自动恢复上一个已验证 Profile=${previous_profile} 的服务拓扑。"
      VPSINIT_ALLOW_PROFILE_SWITCH=1 "$ROOT_DIR/vps-init" apply "$backup" || rollback_rc=$?
      if (( rollback_rc == 0 )); then
        log_ok "已恢复上一个已验证 Profile=${previous_profile}。"
      else
        log_warn "自动回滚未完全成功（exit=${rollback_rc}）；保留原配置，请运行 vps-init apply 重新收敛。"
      fi
    fi
  fi
  rm -f "$pending"
  [[ -n "$backup" ]] && rm -f "$backup"
  return "$rc"
}
