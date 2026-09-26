#!/usr/bin/env bash
optional_docker() {
  is_true "$ENABLE_DOCKER" || return 0
  log_info "安装 Docker 官方 Engine..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  source /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  mkdir -p /etc/docker
  if [[ -f /etc/docker/daemon.json ]]; then backup_file /etc/docker/daemon.json; fi
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
JSON
  systemctl enable --now docker
  docker version >/dev/null
  docker compose version >/dev/null
  log_warn "Docker 会修改 iptables。以后部署容器时优先绑定 127.0.0.1:host:container，再经 Nginx/Lucky 对外暴露。"
  log_ok "Docker 安装完成。"
}
