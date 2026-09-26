#!/usr/bin/env bash
core_preflight() {
  require_root
  local had_state=false
  [[ -f "$STATE_FILE" ]] && had_state=true
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "V1 仅支持 Ubuntu 24.04 LTS；当前: ${PRETTY_NAME:-unknown}"
  [[ "${VERSION_ID:-}" == "24.04" ]] || die "V1 仅支持 Ubuntu 24.04 LTS；当前: ${PRETTY_NAME:-unknown}"

  if ! command_exists curl; then wait_apt_lock 300; apt-get update -qq; apt-get install -y curl; fi
  command_exists ip || die "缺少 iproute2。"
  command_exists ss || die "缺少 ss/iproute2。"

  local detected_ip detected_ipv6 detected_if
  detected_ip="$(get_public_ipv4)"
  detected_ipv6="$(get_public_ipv6 || true)"
  detected_if="$(get_default_interface)"
  if [[ -n "${SERVER_IP:-}" && "$SERVER_IP" != "$detected_ip" ]]; then
    log_warn "检测到公网 IPv4 已变化：state=${SERVER_IP} current=${detected_ip}，将使用当前地址。"
  fi
  SERVER_IP="$detected_ip"
  SERVER_IPV6="$detected_ipv6"
  DEFAULT_INTERFACE="$detected_if"
  [[ -n "$SERVER_IP" ]] || die "无法确定 IPv4。"
  [[ -n "$DEFAULT_INTERFACE" ]] || die "无法确定默认网卡。"
  if profile_has_xui && is_private_ipv4 "$SERVER_IP"; then
    die "检测到的 IPv4 ${SERVER_IP} 不是公网地址。Reality/公网订阅 Profile 需要可从互联网访问的公网 IPv4。"
  fi

  log_info "系统: ${PRETTY_NAME}"
  log_info "公网 IPv4: $SERVER_IP"
  [[ -n "$SERVER_IPV6" ]] && log_info "公网 IPv6: $SERVER_IPV6"
  log_info "默认网卡: $DEFAULT_INTERFACE"
  log_info "CPU: $(nproc) 核；内存: $(awk '/MemTotal/{printf "%.0f MiB",$2/1024}' /proc/meminfo)；根分区可用: $(df -h / | awk 'NR==2{print $4}')"
  log_info "当前监听端口："
  ss -ltnup 2>/dev/null | sed -n '1,30p' || true

  if [[ "$PROFILE" == "reality-only" || "$PROFILE" == "lucky-reality" ]]; then
    if port_in_use 443 && ! systemctl is-active --quiet x-ui 2>/dev/null; then
      die "443 已被其他服务占用。为避免覆盖现有服务，已停止。"
    fi
  fi
  if [[ "$PROFILE" == "reality-only" ]] && port_in_use 80; then
    die "reality-only 的 3x-ui IP SSL 需要 80/tcp 做 HTTP-01，但 80 已被占用。"
  fi
  if [[ "$PROFILE" == "nginx-reality" ]] && port_in_use 443 && ! systemctl is-active --quiet nginx 2>/dev/null; then
    die "443 已被非 Nginx 服务占用。为避免覆盖现有服务，已停止。"
  fi

  # Fresh-server safety: an existing stack not previously managed by vps-init needs explicit adoption.
  if [[ "$had_state" == false ]]; then
    local existing=()
    profile_has_xui && [[ -x /usr/local/x-ui/x-ui ]] && existing+=("3x-ui")
    [[ "$PROFILE" == "nginx-reality" ]] && command_exists nginx && existing+=("nginx")
    [[ "$PROFILE" == "lucky-reality" && -x /opt/lucky/lucky ]] && existing+=("Lucky")
    if (( ${#existing[@]} > 0 )); then
      log_warn "检测到并非由本项目 state 标记的已有组件：${existing[*]}"
      if ! confirm "允许 vps-init 接管这些组件并修改配置？" n; then
        die "为保护现有 VPS 配置，已停止。建议在全新 Ubuntu 24.04 VPS 上使用。"
      fi
    fi
    if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
      log_warn "检测到已有 UFW 规则。apply 会按当前 Profile 重建 UFW 规则集。"
      if ! confirm "允许重建现有 UFW 规则？" n; then
        die "未授权修改现有 UFW，已停止。"
      fi
    fi
  fi

  state_set SERVER_IP "$SERVER_IP"
  state_set SERVER_IPV6 "$SERVER_IPV6"
  state_set DEFAULT_INTERFACE "$DEFAULT_INTERFACE"
  state_set DEPLOYED_PROFILE "$PROFILE"

  mkdir -p "$BACKUP_DIR"
  log_ok "预检完成。"
}
