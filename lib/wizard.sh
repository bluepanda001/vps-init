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

wizard_set_profile_choice() {
  case "$1" in
    1) W_PROFILE="reality-only"; W_INSTALL_NODE="true";  W_GATEWAY="none" ;;
    2) W_PROFILE="lucky-reality"; W_INSTALL_NODE="true";  W_GATEWAY="lucky" ;;
    3) W_PROFILE="nginx-reality"; W_INSTALL_NODE="true";  W_GATEWAY="nginx" ;;
    4) W_PROFILE="lucky-web";     W_INSTALL_NODE="false"; W_GATEWAY="lucky" ;;
    5) W_PROFILE="base-only";     W_INSTALL_NODE="false"; W_GATEWAY="none" ;;
    *) return 1 ;;
  esac
  W_ENABLE_CF_WS="false"
  W_ENABLE_DOCKER="false"
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
  if [[ "$W_PROFILE" != "lucky-web" ]]; then
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
  fi

  if [[ "$W_PROFILE" == "lucky-reality" || "$W_PROFILE" == "lucky-web" ]]; then
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

wizard_reinstall() {
  # Destructive reinstall is deliberately separate from the normal install wizard.
  local reinstall_repo="bin456789/reinstall"
  local reinstall_commit="2bcbc96100fe733bf9a16d609f799246f62666e5"
  local virt confirm_word script current_port key dd_password="" dd_password2=""
  local -a cmd existing_keys

  require_root
  [[ -t 0 ]] || die "系统重装需要交互式终端。"
  wizard_banner
  echo
  echo "============================================================"
  echo "                 系统重装 / 一键 DD"
  echo "============================================================"
  echo "目标系统：Ubuntu 24.04 Minimal"
  echo "上游：$reinstall_repo"
  echo "固定提交：$reinstall_commit"
  echo
  echo "警告：重装会清除主硬盘全部数据，包括所有分区。"
  echo "当前 vps-init、3x-ui、Docker、网站、证书等磁盘数据都会被删除。"
  echo

  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "$virt" in
    openvz|lxc|lxc-libvirt)
      die "检测到 $virt。bin456789/reinstall 官方明确不支持 OpenVZ/LXC；不会继续 DD。"
      ;;
  esac

  read -r -p "确认清空整盘并重装 Ubuntu 24.04 Minimal，请输入大写 DD： " confirm_word
  [[ "$confirm_word" == "DD" ]] || { echo "未输入 DD，已取消。"; return 0; }

  script="/root/reinstall.sh"
  curl -fL --retry 3 --connect-timeout 10 --max-time 60 -o "$script" \
    "https://raw.githubusercontent.com/$reinstall_repo/$reinstall_commit/reinstall.sh"
  chmod 700 "$script"

  # Upstream currently echoes the plaintext password in several summary blocks.
  # vps-init never needs that behavior, so redact it before execution.
  sed -i -E 's/echo "Password: \$password"/echo "Password: [hidden]"/g' "$script"

  current_port="$(wizard_detect_ssh_port)"
  mapfile -t existing_keys < <(wizard_existing_ed25519_keys || true)

  cmd=(bash "$script" ubuntu 24.04 --minimal --user root --ssh-port "$current_port")
  if (( ${#existing_keys[@]} > 0 )); then
    echo
    echo "检测到当前 root 的 ${#existing_keys[@]} 把 ED25519 公钥。DD 后会全部保留；vps-main 会优先传入。"
    for key in "${existing_keys[@]}"; do
      cmd+=(--ssh-key "$key")
    done
    # Upstream rejects --password together with --ssh-key. With keys present,
    # it skips the password prompt and configures key-based login only.
    # Do not pass a password here; this also avoids enabling password auth.
  else
    echo
    echo "当前没有检测到 root 的 ED25519 authorized key。"
    echo "请设置重装后的临时 root SSH 密码（输入不会显示）："
    while true; do
      read -r -s -p "密码: " dd_password; echo
      [[ ${#dd_password} -ge 10 ]] || { echo "密码至少 10 个字符。"; continue; }
      read -r -s -p "再次输入: " dd_password2; echo
      [[ "$dd_password" == "$dd_password2" ]] || { echo "两次密码不一致，请重新输入。"; continue; }
      break
    done
    cmd+=(--password "$dd_password")
  fi

  echo
  echo "开始准备一键重装（真正清盘会在 reboot 后开始）..."
  "${cmd[@]}" 2>&1 | sed -E 's/^([[:space:]]*(Password|密码)[[:space:]]*:).*/\1 [hidden]/I'
  unset dd_password dd_password2

  echo
  echo "============================================================"
  echo "Ubuntu 24.04 Minimal 重装已经准备好。"
  echo
  echo "重启前如果改变主意，可运行："
  echo "  bash /root/reinstall.sh reset"
  echo
  echo "系统装好重新 SSH 登录后，直接运行："
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/bluepanda001/vps-init/main/install.sh)"
  echo
  echo "新系统会直接进入安装方式 / Profile 选择，不会再次询问是否 DD。"
  echo "============================================================"
  echo

  if wizard_yesno "现在立即 reboot 开始重装？" y; then
    sync
    systemctl reboot
    # A requested reboot is a successful terminal action; do not propagate a
    # synthetic non-zero status that the global ERR trap could report as failure.
    exit 0
  fi

  echo "已暂缓 reboot。准备好后手动执行：reboot"
  return 0
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
    echo "服务器公钥位置：/root/.ssh/authorized_keys"
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

Windows 公钥文件：$env:USERPROFILE\.ssh\vps-main-ed25519.pub
VPS 写入位置：/root/.ssh/authorized_keys

生成后，把无 .pub 后缀的私钥导入 Netcatty Keychain，Label 固定为 vps-main。
私钥只保存在 Windows / Netcatty Keychain，绝对不要上传到 VPS、GitHub 或聊天。
EOF2
  elif [[ "$choice" == 3 && -n "$existing_any" ]]; then
    echo "服务器公钥位置：/root/.ssh/authorized_keys"
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

  # Normal installation starts directly with install mode/profile. Destructive
  # reinstall is intentionally a separate `vps-init reinstall` workflow.
  local mode_choice profile_choice current_port custom advanced_prompt
  W_CUSTOM_ADVANCED="false"
  while true; do
    mode_choice="$(wizard_select "安装方式：" \
      "快速安装（默认参数，推荐）" \
      "自定义安装（按需启用可选功能/高级参数）")"
    custom="false"
    [[ "$mode_choice" == 2 ]] && custom="true"

    profile_choice="$(wizard_select "部署方案（选一项即可，依赖组件会自动配置）：" \
      "Reality 节点（IP 直连，不需要域名）" \
      "Reality + Lucky（需要域名，自动配置 443 复用）" \
      "Reality + Nginx（需要域名，HTTPS 入口）" \
      "仅 Lucky Web 服务（需要域名，不部署代理节点）" \
      "仅系统初始化（不安装节点或 Web 网关）")"
    wizard_set_profile_choice "$profile_choice" || die "部署方案无效。"

    if [[ "$custom" == true ]]; then
      if [[ "$W_PROFILE" == "lucky-reality" || "$W_PROFILE" == "nginx-reality" ]]; then
        if wizard_yesno "额外启用 Cloudflare CDN WS 备用节点？" n; then
          W_ENABLE_CF_WS="true"
        fi
      fi
      if wizard_yesno "额外安装 Docker Engine/Compose（供后续容器应用使用）？" n; then
        W_ENABLE_DOCKER="true"
      fi

      case "$W_PROFILE" in
        base-only|lucky-web)
          advanced_prompt="需要修改高级参数（SSH 端口）？"
          ;;
        *)
          advanced_prompt="需要修改高级参数（SSH 端口、Reality Target、面板/订阅路径）？"
          ;;
      esac
      if wizard_yesno "$advanced_prompt" n; then
        W_CUSTOM_ADVANCED="true"
      fi
    else
      [[ "$W_PROFILE" == "lucky-web" ]] && W_ENABLE_DOCKER="true"
      if [[ "$W_PROFILE" == "nginx-reality" || "$W_PROFILE" == "lucky-reality" ]]; then
        W_ENABLE_CF_WS="true"
      fi
    fi
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
  if [[ "$custom" == true && "$W_CUSTOM_ADVANCED" == true ]]; then
    W_SSH_PORT="$(wizard_prompt_default "SSH 端口" "$current_port")"
  else
    W_SSH_PORT="$current_port"
    echo "SSH 端口：$W_SSH_PORT（沿用当前连接）"
  fi
  [[ "$W_SSH_PORT" =~ ^[0-9]+$ ]] && ((W_SSH_PORT>=1 && W_SSH_PORT<=65535)) || die "SSH 端口无效。"
  wizard_collect_ssh_key
  wizard_collect_admin_credentials

  W_ROOT_DOMAIN=""; W_LE_EMAIL=""
  if [[ "$W_PROFILE" == "nginx-reality" || "$W_PROFILE" == "lucky-reality" || "$W_PROFILE" == "lucky-web" ]]; then
    echo
    while [[ -z "$W_ROOT_DOMAIN" ]]; do
      W_ROOT_DOMAIN="$(wizard_prompt_default "Cloudflare 根域名（例如 example.com）" "")"
      [[ "$W_ROOT_DOMAIN" != *://* && "$W_ROOT_DOMAIN" != */* && "$W_ROOT_DOMAIN" == *.* ]] || { echo "请只填写根域名，不要带 https:// 或路径。"; W_ROOT_DOMAIN=""; }
    done
    W_LE_EMAIL="$(wizard_prompt_default "Let's Encrypt 邮箱（可留空）" "")"
  fi

  W_REALITY_TARGET_MODE="auto"; W_REALITY_TARGET=""
  if [[ "$W_PROFILE" != "base-only" && "$W_PROFILE" != "lucky-web" && "$custom" == true && "$W_CUSTOM_ADVANCED" == true ]]; then
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
  if [[ "$custom" == true && "$W_CUSTOM_ADVANCED" == true && "$W_PROFILE" != "base-only" && "$W_PROFILE" != "lucky-web" ]]; then
    W_PANEL_PATH="$(normalize_path "$(wizard_prompt_default "3x-ui 面板 URI Path" "/zhg/")")"
    local sub_input
    sub_input="$(wizard_prompt_default "订阅 URI Path" "/zhg/")"
    W_SUB_PATH="$(normalize_path "$sub_input")"
    W_SUBSCRIPTION_PORT="$(wizard_prompt_default "3x-ui Subscription 内部/直连端口" "2096")"
    [[ "$W_SUBSCRIPTION_PORT" =~ ^[0-9]+$ ]] && ((W_SUBSCRIPTION_PORT>=1 && W_SUBSCRIPTION_PORT<=65535)) || die "订阅端口无效。"
  fi
  echo
  echo "================ 部署确认 ================"
  case "$W_PROFILE" in
    reality-only)  echo "方案：Reality 节点（IP 直连）" ;;
    lucky-reality) echo "方案：Reality + Lucky（自动复用 443）" ;;
    nginx-reality) echo "方案：Reality + Nginx（HTTPS 入口）" ;;
    lucky-web)     echo "方案：仅 Lucky Web 服务" ;;
    base-only)     echo "方案：仅系统初始化" ;;
  esac
  echo "服务器：$W_SERVER_NAME"
  echo "公网 IP：$W_SERVER_IP"
  echo "SSH 端口：$W_SSH_PORT"
  [[ -n "$W_ROOT_DOMAIN" ]] && echo "根域名：$W_ROOT_DOMAIN"

  if [[ "$W_PROFILE" != "base-only" && "$W_PROFILE" != "lucky-web" ]]; then
    echo
    echo "节点配置"
    echo "  3x-ui + VLESS Reality：安装"
    echo "  面板路径：$W_PANEL_PATH"
    echo "  订阅路径/端口：$W_SUB_PATH / $W_SUBSCRIPTION_PORT"
    echo "  Reality Target：${W_REALITY_TARGET_MODE}${W_REALITY_TARGET:+ ($W_REALITY_TARGET)}"
    echo "  Clash/Mihomo 订阅：启用"
    if [[ -n "${W_XUI_USERNAME_INPUT:-}${W_XUI_PASSWORD_INPUT:-}" ]]; then
      echo "  3x-ui 账号密码：使用自定义值"
    else
      echo "  3x-ui 账号密码：保持现有值或自动生成"
    fi
  fi

  if [[ "$W_PROFILE" == "lucky-reality" || "$W_PROFILE" == "lucky-web" ]]; then
    echo
    echo "Web 服务"
    echo "  Lucky：安装"
    [[ "$W_PROFILE" == "lucky-web" ]] && echo "  Lucky 管理域名：lucky.$W_ROOT_DOMAIN"
    if [[ -n "${W_LUCKY_USERNAME_INPUT:-}${W_LUCKY_PASSWORD_INPUT:-}" ]]; then
      echo "  Lucky 账号密码：使用自定义值"
    else
      echo "  Lucky 账号密码：保持现有值或自动生成"
    fi
  elif [[ "$W_PROFILE" == "nginx-reality" ]]; then
    echo
    echo "Web 入口"
    echo "  Nginx HTTPS：安装"
  fi

  echo
  echo "可选组件"
  echo "  Docker：$([[ "$W_ENABLE_DOCKER" == true ]] && echo "安装" || echo "不安装")"
  if [[ "$W_PROFILE" == "nginx-reality" || "$W_PROFILE" == "lucky-reality" ]]; then
    echo "  Cloudflare CDN WS：$([[ "$W_ENABLE_CF_WS" == true ]] && echo "启用" || echo "不启用")"
  fi
  echo "=========================================="
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
