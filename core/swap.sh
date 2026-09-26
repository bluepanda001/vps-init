#!/usr/bin/env bash
core_swap() {
  if swapon --show=NAME --noheadings | grep -q .; then
    log_info "检测到现有 Swap，保持不变：$(swapon --show --bytes --noheadings | head -1)"
  else
    local mem_kb size_mb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    if (( mem_kb < 2*1024*1024 )); then size_mb=2048
    elif (( mem_kb < 4*1024*1024 )); then size_mb=2048
    else size_mb=1024; fi
    log_info "创建 ${size_mb} MiB /swapfile..."
    fallocate -l "${size_mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=progress
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  cat > /etc/sysctl.d/98-vps-init-swap.conf <<'SYS'
vm.swappiness=20
SYS
  sysctl --system >/dev/null
  log_ok "Swap / swappiness 完成。"
}
