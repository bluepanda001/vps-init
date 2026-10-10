#!/usr/bin/env bash
# Firewall baseline for ALL profiles: TCP 22, 80, 443.
# Other TCP ports (such as a verified custom SSH or a public subscription)
# are opened only when required by configuration. No UDP ports are added.

vpsinit_ufw_desired_tcp_ports() {
  printf '%s\n' 22 80 443
  if [[ "${SSH_PORT:-22}" != 22 ]]; then
    printf '%s\n' "$SSH_PORT"
  fi
  case "$PROFILE" in
    reality-only)
      if is_true "${ENABLE_SUBSCRIPTION_RESOLVED:-false}"; then
        printf '%s\n' "$SUBSCRIPTION_PORT"
      fi
      ;;
    nginx-reality|lucky-reality)
      if [[ "${SUBSCRIPTION_EXPOSE_MODE_RESOLVED:-}" == direct-ip-https ]] &&
         is_true "${ENABLE_SUBSCRIPTION_RESOLVED:-false}"; then
        printf '%s\n' "$SUBSCRIPTION_PORT"
      fi
      ;;
  esac
}

# This reconciles only vps-init's obsolete TCP entries. Unlike the old code,
# it never removes the baseline or a current SSH port before allowing it.
# Re-read rule numbers after each deletion because UFW renumbers them.
remove_stale_vps_init_ufw_rules() {
  local -a wanted=("$@")
  local line num port proto keep candidate removed
  local rounds=0

  while (( rounds < 100 )); do
    removed=false
    while IFS= read -r line; do
      [[ "$line" == *"# vps-init "* ]] || continue
      if [[ ! "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+([0-9]+)/([[:alpha:]]+) ]]; then
        log_warn "未识别的 vps-init UFW 规则，保留以避免误删：$line"
        continue
      fi
      num="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[2]}"
      proto="${BASH_REMATCH[3]}"
      # Never silently remove a UDP rule; UDP is administrator opt-in.
      [[ "$proto" == tcp ]] || continue
      keep=false
      for candidate in "${wanted[@]}"; do
        if [[ "$port" == "$candidate" ]]; then keep=true; break; fi
      done
      [[ "$keep" == true ]] && continue

      ufw --force delete "$num" >/dev/null || die "清理过期 UFW 规则 #$num 失败；保留当前网络连接并中止。"
      removed=true
      break
    done < <(ufw status numbered 2>/dev/null)

    [[ "$removed" == true ]] || return 0
    rounds=$((rounds + 1))
  done

  die "存在过多过期 UFW 规则（超过 100 条），停止自动清理，防止误操作。"
}


# Verify the unrestricted IPv4 allow rule; a v6-only rule is insufficient for
# IPv4 HTTP-01 validation. This checks presence, not an external end-to-end
# network probe (cloud-provider firewalls can still block inbound traffic).
vpsinit_ufw_tcp_allowed() {
  local port="$1"
  ufw status 2>/dev/null |
    grep -Eq "^${port}/tcp[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]]+Anywhere([[:space:]]|$)"
}

core_firewall() {
  log_info "配置 UFW（所有 Profile 默认 TCP 22/80/443；UDP 按需）..."
  mkdir -p "$BACKUP_DIR/ufw"
  ufw status numbered > "$BACKUP_DIR/ufw/status-before.txt" 2>&1 || true
  [[ -f /etc/ufw/user.rules ]] && cp -a /etc/ufw/user.rules "$BACKUP_DIR/ufw/user.rules" || true
  [[ -f /etc/ufw/user6.rules ]] && cp -a /etc/ufw/user6.rules "$BACKUP_DIR/ufw/user6.rules" || true

  local was_active=false port
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    was_active=true
  fi

  local -a wanted=()
  mapfile -t wanted < <(vpsinit_ufw_desired_tcp_ports | sort -nu)
  [[ "${#wanted[@]}" -gt 0 ]] || die "内部错误：UFW 目标端口列表为空。"

  # Add first. In particular, never delete the active SSH allow rule even
  # for a fraction of a second when a connection is being used remotely.
  for port in "${wanted[@]}"; do
    case "$port" in
      22) ufw allow 22/tcp comment 'vps-init ssh-baseline' >/dev/null ;;
      80) ufw allow 80/tcp comment 'vps-init http-acme' >/dev/null ;;
      443) ufw allow 443/tcp comment 'vps-init https-reality' >/dev/null ;;
      *)
        if [[ "$port" == "$SSH_PORT" ]]; then
          ufw allow "${port}/tcp" comment 'vps-init ssh-custom' >/dev/null
        else
          ufw allow "${port}/tcp" comment 'vps-init subscription' >/dev/null
        fi
        ;;
    esac
  done

  # Existing active firewall settings and administrator-added rules are
  # preserved. Only a newly enabled firewall receives the safe defaults.
  if [[ "$was_active" == false ]]; then
    ufw default deny incoming
    ufw default allow outgoing
  fi

  # Remove only obsolete project-tagged TCP rules, after ensuring SSH remains
  # reachable. Unmanaged rules, including manual UDP rules, are untouched.
  remove_stale_vps_init_ufw_rules "${wanted[@]}"

  if [[ "$was_active" == false ]]; then
    ufw --force enable
  fi
  log_ok "UFW 已配置：TCP 22/80/443 默认开放，其他 TCP 按需；UDP 未新增，管理员规则未重置。"
}
