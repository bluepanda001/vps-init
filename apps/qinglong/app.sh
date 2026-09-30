#!/usr/bin/env bash

QINGLONG_ID="qinglong"
QINGLONG_IMAGE="whyour/qinglong:latest"
QINGLONG_CONTAINER="vpsinit-qinglong"

qinglong_compose_file() {
  printf '%s/qinglong/compose.yml\n' "$APP_ROOT"
}

qinglong_installed() {
  command_exists docker && app_state_exists "$QINGLONG_ID" && docker inspect "$QINGLONG_CONTAINER" >/dev/null 2>&1
}

qinglong_write_compose() {
  local port="$1" dir="$APP_ROOT/qinglong"
  mkdir -p "$dir/data"
  chmod 700 "$dir"
  cat > "$dir/compose.yml" <<EOF2
name: vpsinit-qinglong
services:
  qinglong:
    image: ${QINGLONG_IMAGE}
    container_name: ${QINGLONG_CONTAINER}
    hostname: qinglong
    restart: unless-stopped
    ports:
      - "127.0.0.1:${port}:5700"
    volumes:
      - "./data:/ql/data"
    environment:
      QlBaseUrl: "/"
      QlPort: "5700"
EOF2
}

qinglong_install() {
  local domain="${1:-}"
  app_core_context
  ensure_docker_runtime

  local port=""
  app_state_load "$QINGLONG_ID"
  port="${LOCAL_PORT:-}"
  if [[ -z "$port" ]]; then
    port="$(app_select_port 5700)"
  fi

  if [[ -z "$domain" && -n "${ROOT_DOMAIN:-}" && "$PROFILE" == "nginx-reality" ]]; then
    domain="ql.${ROOT_DOMAIN}"
  fi

  log_info "安装青龙面板（Docker）：${QINGLONG_IMAGE}"
  qinglong_write_compose "$port"
  (
    cd "$APP_ROOT/qinglong"
    docker compose pull
    docker compose up -d
  )
  app_wait_http "$port" "/" 60 || die "青龙容器已启动，但 127.0.0.1:${port} 未通过 HTTP 检查。"

  app_state_set "$QINGLONG_ID" APP_ID "$QINGLONG_ID"
  app_state_set "$QINGLONG_ID" APP_NAME "青龙面板"
  app_state_set "$QINGLONG_ID" INSTALL_METHOD "docker"
  app_state_set "$QINGLONG_ID" MANAGED_BY "vps-init"
  app_state_set "$QINGLONG_ID" IMAGE "$QINGLONG_IMAGE"
  app_state_set "$QINGLONG_ID" CONTAINER "$QINGLONG_CONTAINER"
  app_state_set "$QINGLONG_ID" LOCAL_HOST "127.0.0.1"
  app_state_set "$QINGLONG_ID" LOCAL_PORT "$port"
  app_state_set "$QINGLONG_ID" DATA_DIR "$APP_ROOT/qinglong/data"
  app_state_set "$QINGLONG_ID" WEBSOCKET "true"

  if [[ -n "$domain" ]]; then
    gateway_nginx_add "$QINGLONG_ID" "$domain" "$port" true
  else
    app_state_set "$QINGLONG_ID" PROXY_ENABLED "false"
    app_state_set "$QINGLONG_ID" PUBLIC_URL ""
  fi

  local digest
  digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$QINGLONG_IMAGE" 2>/dev/null || true)"
  app_state_set "$QINGLONG_ID" IMAGE_DIGEST "$digest"
  app_state_set "$QINGLONG_ID" INSTALLED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  qinglong_verify
  log_ok "青龙安装完成。"
  qinglong_status
}

qinglong_status() {
  app_state_load "$QINGLONG_ID"
  local running="未安装" health="未知"
  if command_exists docker && docker inspect "$QINGLONG_CONTAINER" >/dev/null 2>&1; then
    running="$(docker inspect -f '{{.State.Status}}' "$QINGLONG_CONTAINER" 2>/dev/null || true)"
    if [[ -n "${LOCAL_PORT:-}" ]] && app_local_http_ok "$LOCAL_PORT"; then health="正常"; else health="异常"; fi
  fi
  echo "============================================================"
  echo "                    青龙面板"
  echo "============================================================"
  echo "安装方式： ${INSTALL_METHOD:-未安装}"
  echo "容器状态： ${running}"
  echo "本地检查： ${health}"
  [[ -n "${LOCAL_PORT:-}" ]] && echo "本地地址： http://127.0.0.1:${LOCAL_PORT}"
  [[ -n "${PUBLIC_URL:-}" ]] && echo "公网地址： ${PUBLIC_URL}"
  [[ -n "${DOMAIN:-}" ]] && echo "反向代理： ${PROXY_PROVIDER:-none} / ${DOMAIN}"
  [[ -n "${IMAGE_DIGEST:-}" ]] && echo "镜像摘要： ${IMAGE_DIGEST}"
  echo "数据目录： ${DATA_DIR:-$APP_ROOT/qinglong/data}"
  echo "============================================================"
}

qinglong_verify() {
  app_state_load "$QINGLONG_ID"
  [[ -n "${LOCAL_PORT:-}" ]] || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$QINGLONG_CONTAINER" 2>/dev/null || true)" == "true" ]] || return 1
  app_local_http_ok "$LOCAL_PORT" || return 1
  if is_true "${PROXY_ENABLED:-false}"; then
    gateway_nginx_verify "$QINGLONG_ID" "$DOMAIN" || return 1
  fi
  return 0
}

qinglong_update() {
  app_state_load "$QINGLONG_ID"
  [[ -f "$(qinglong_compose_file)" ]] || die "青龙尚未由应用中心安装。"
  ensure_docker_runtime
  (
    cd "$APP_ROOT/qinglong"
    docker compose pull
    docker compose up -d
  )
  app_wait_http "$LOCAL_PORT" "/" 60 || die "青龙更新后本地 HTTP 检查失败。"
  local digest
  digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$QINGLONG_IMAGE" 2>/dev/null || true)"
  app_state_set "$QINGLONG_ID" IMAGE_DIGEST "$digest"
  qinglong_verify || die "青龙更新后验收失败。"
  log_ok "青龙已更新并验收通过。"
}

qinglong_remove() {
  app_state_load "$QINGLONG_ID"
  if [[ -f "$(qinglong_compose_file)" ]]; then
    (cd "$APP_ROOT/qinglong" && docker compose down)
  fi
  gateway_nginx_remove "$QINGLONG_ID"
  mkdir -p "$APP_STATE_DIR"
  rm -f "$(app_state_file "$QINGLONG_ID")"
  log_warn "青龙容器和反向代理已删除；数据目录保留：$APP_ROOT/qinglong/data"
}
