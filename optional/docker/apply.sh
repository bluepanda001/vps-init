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

docker_install_repo_url() {
  # Only the Docker CE apt package source is selected here. This does NOT
  # rewrite Docker Hub registries or existing daemon.json registry-mirrors.
  case "${DOCKER_INSTALL_SOURCE:-official}" in
    official) printf '%s\n' 'https://download.docker.com/linux/ubuntu' ;;
    aliyun)  printf '%s\n' 'https://mirrors.aliyun.com/docker-ce/linux/ubuntu' ;;
    *) die "无效的 Docker 安装源：${DOCKER_INSTALL_SOURCE}" ;;
  esac
}

optional_docker() {
  is_true "$ENABLE_DOCKER" || return 0
  local repo_url tmp_key
  repo_url="$(docker_install_repo_url)"
  log_info "确保 Docker Engine / Compose 可用；软件包源：${DOCKER_INSTALL_SOURCE:-official} (${repo_url})..."
  install -m 0755 -d /etc/apt/keyrings
  tmp_key="$(mktemp)"
  if ! curl -fL --retry 3 --connect-timeout 10 --max-time 90 -o "$tmp_key" "$repo_url/gpg"; then
    rm -f "$tmp_key"
    die "Docker 软件包源 GPG 公钥下载失败：$repo_url/gpg"
  fi
  if ! gpg --batch --show-keys "$tmp_key" >/dev/null 2>&1; then
    rm -f "$tmp_key"
    die "Docker 安装源返回的 GPG 公钥无效；不会替换已有密钥。"
  fi
  install -m 0644 "$tmp_key" /etc/apt/keyrings/docker.asc
  rm -f "$tmp_key"

  local os_codename
  os_codename="$(
    set +u
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${VERSION_CODENAME:-}"
  )"
  [[ -n "$os_codename" ]] || die "无法从 /etc/os-release 获取 VERSION_CODENAME。"

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${repo_url} ${os_codename} stable" > /etc/apt/sources.list.d/docker.list
  apt_get_with_lock_retry update
  apt_get_with_lock_retry install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  docker_merge_daemon_config

  systemctl enable --now docker
  docker version >/dev/null
  docker compose version >/dev/null
  log_warn "Docker 会修改 iptables。以后部署容器时优先绑定 127.0.0.1:host:container，再经 Nginx/Lucky 对外暴露。"
  log_ok "Docker 安装完成。"
}
