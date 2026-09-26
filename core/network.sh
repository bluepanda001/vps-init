#!/usr/bin/env bash
core_network() {
  cat > /etc/sysctl.d/99-network-tuning.conf <<'SYS'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
  sysctl --system >/dev/null
  local cc qdisc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  [[ "$cc" == "bbr" ]] || log_warn "BBR 当前未显示为 bbr（内核/虚拟化可能限制），最终验收会再次检查。"
  log_ok "网络调优: congestion_control=${cc:-unknown}, qdisc=${qdisc:-unknown}"
}
