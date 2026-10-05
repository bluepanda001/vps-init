#!/usr/bin/env bash

docker_merge_daemon_config() {
  local cfg=/etc/docker/daemon.json tmp restore=""
  mkdir -p /etc/docker
  tmp="$(mktemp)"

  if [[ -f "$cfg" ]]; then
    python3 -m json.tool "$cfg" >/dev/null 2>&1 ||
      die "现有 $cfg 不是有效 JSON；为避免破坏 Docker 配置，已停止且不会覆盖。"
    python3 "$ROOT_DIR/optional/docker/merge_daemon.py" --input "$cfg" --output "$tmp" ||
      { rm -f "$tmp"; die "Docker daemon.json 合并失败；原配置未修改。"; }
  else
    python3 "$ROOT_DIR/optional/docker/merge_daemon.py" --output "$tmp" ||
      { rm -f "$tmp"; die "Docker daemon.json 生成失败。"; }
  fi

  dockerd --validate --config-file "$tmp" >/dev/null ||
    { rm -f "$tmp"; die "合并后的 Docker daemon.json 未通过 dockerd --validate；原配置未修改。"; }

  if [[ -f "$cfg" ]] && cmp -s "$cfg" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi

  if [[ -f "$cfg" ]]; then
    backup_file "$cfg"
    restore="$(mktemp)"
    cp -a "$cfg" "$restore"
  fi
  install -m 644 "$tmp" "$cfg"
  rm -f "$tmp"

  if systemctl is-active --quiet docker 2>/dev/null; then
    if ! systemctl restart docker; then
      log_error "Docker 新配置生效失败，正在恢复原 daemon.json。"
      if [[ -n "$restore" && -f "$restore" ]]; then
        install -m 644 "$restore" "$cfg"
      else
        rm -f "$cfg"
      fi
      systemctl restart docker >/dev/null 2>&1 || true
      rm -f "$restore"
      die "Docker 重启失败；已尝试恢复部署前配置。"
    fi
  fi
  rm -f "$restore"
  log_ok "Docker daemon.json 已安全合并；现有 data-root/镜像源/网络/runtime 等字段均保留。"
}

optional_docker() {
  is_true "$ENABLE_DOCKER" || return 0
  log_info "确保 Docker 官方 Engine / Compose 可用..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  local os_codename
  os_codename="$(
    set +u
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${VERSION_CODENAME:-}"
  )"
  [[ -n "$os_codename" ]] || die "无法从 /etc/os-release 获取 VERSION_CODENAME。"

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${os_codename} stable" > /etc/apt/sources.list.d/docker.list
  apt_get_with_lock_retry update
  apt_get_with_lock_retry install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  docker_merge_daemon_config

  systemctl enable --now docker
  docker version >/dev/null
  docker compose version >/dev/null
  log_warn "Docker 会修改 iptables。以后部署容器时优先绑定 127.0.0.1:host:container，再经 Nginx/Lucky 对外暴露。"
  log_ok "Docker 安装完成。"
}
