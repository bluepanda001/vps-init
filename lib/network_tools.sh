#!/usr/bin/env bash
# Optional post-deploy network tuning and TCP diagnostics.
# Third-party entry scripts are pinned to immutable upstream commits so a
# released VPS Init version does not silently change behavior when upstream main moves.

TCPFIT_REF="38fbf5af30daf87735f2ffbc5e0905033ee2b86e"
TCPFIT_VERSION="0.5.9"
TCPFIT_SHA256="8331cc40950229a3280ce32406330a85b1a3d21ba398a4db3dc7e25c39783741"
TCPFIT_URL="https://raw.githubusercontent.com/Kylin010/tcpfit/${TCPFIT_REF}/tcpfit.sh"

TCPQUALITY_REF="1b58a192c881e9eb500910997f14fde7c2c607ef"
TCPQUALITY_ENTRY_BLOB_SHA1="a115699ba3bd5ef8c7a975d3c8e50a130fdf4331"
TCPQUALITY_RAW_BASE="https://raw.githubusercontent.com/ibsgss/TcpQuality/${TCPQUALITY_REF}"
TCPQUALITY_URL="${TCPQUALITY_RAW_BASE}/runTcpQuality.sh"

network_tools_need_curl() {
  command -v curl >/dev/null 2>&1 || die "网络工具需要 curl；请先安装 curl 后重试。"
}

network_tools_download() {
  local url="$1" out="$2"
  network_tools_need_curl
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$out" ||
    die "下载第三方网络工具失败：$url"
  [[ -s "$out" ]] || die "下载结果为空：$url"
  chmod 0700 "$out"
}

network_tools_tcpfit() {
  require_root
  local tmp actual rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/vps-init-tcpfit.XXXXXX")"
  network_tools_download "$TCPFIT_URL" "$tmp"

  command -v sha256sum >/dev/null 2>&1 || {
    rm -f "$tmp"
    die "缺少 sha256sum，无法校验 TCPFit。"
  }
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$actual" != "$TCPFIT_SHA256" ]]; then
    rm -f "$tmp"
    die "TCPFit SHA256 校验失败；已拒绝执行。"
  fi

  echo "TCPFit ${TCPFIT_VERSION}（固定 upstream commit ${TCPFIT_REF:0:12}）"
  echo "匿名运行计数已由 VPS Init 默认关闭。"
  if [[ "$#" -eq 0 ]]; then
    echo "进入 TCPFit 菜单；需要完整自动调优时选择：1. 一键调优。"
  fi
  echo

  TCPFIT_NO_TELEMETRY=1 bash "$tmp" "$@" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

network_tools_tcpquality() {
  require_root
  local mode="${1:-speed}" tmp rc=0
  shift || true
  local -a args=()

  case "$mode" in
    speed|ipv4)
      args=(-v4 --only-speedtest --no-rank-upload)
      ;;
    full)
      args=(-v4 --speedtest --no-rank-upload)
      ;;
    route)
      args=(-v4 --route --route-protocol tcp)
      ;;
    gd)
      args=(-v4 --only-speedtest --province gd --no-rank-upload)
      ;;
    raw)
      args=("$@")
      ;;
    -h|--help|help)
      cat <<'EOF'
vps-init tcpquality [mode]

Modes:
  speed   IPv4 only; Beijing/Shanghai/Guangdong x Telecom/Unicom/Mobile speed test (default)
  full    IPv4 only; packet/loss test + the same three-region speed test
  route   IPv4 only; three-carrier return-route identification
  gd      IPv4 only; Guangdong three-carrier speed test
  raw ... Pass arguments directly to pinned TcpQuality upstream entry

Default results are not uploaded for ranking (--no-rank-upload).
EOF
      return 0
      ;;
    *)
      die "未知 TcpQuality 模式：$mode。可用：speed | full | route | gd | raw"
      ;;
  esac

  tmp="$(mktemp "${TMPDIR:-/tmp}/vps-init-tcpquality.XXXXXX")"
  network_tools_download "$TCPQUALITY_URL" "$tmp"

  command -v sha1sum >/dev/null 2>&1 || {
    rm -f "$tmp"
    die "缺少 sha1sum，无法校验 TcpQuality。"
  }
  local size blob_sha
  size="$(wc -c < "$tmp" | tr -d '[:space:]')"
  blob_sha="$({ printf 'blob %s\0' "$size"; cat "$tmp"; } | sha1sum | awk '{print $1}')"
  if [[ "$blob_sha" != "$TCPQUALITY_ENTRY_BLOB_SHA1" ]]; then
    rm -f "$tmp"
    die "TcpQuality Git blob 校验失败；已拒绝执行。"
  fi

  export TCPQUALITY_RAW_BASE
  TCPQUALITY_ROOTFS_SOURCE_ORDER=github bash "$tmp" "${args[@]}" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

network_tools_info() {
  cat <<EOF
TCPFit:
  version : ${TCPFIT_VERSION}
  commit  : ${TCPFIT_REF}
  source  : Kylin010/tcpfit
  verify  : SHA256 pinned
  telemetry: disabled by VPS Init

TcpQuality:
  commit  : ${TCPQUALITY_REF}
  source  : ibsgss/TcpQuality
  default : IPv4 only, Beijing/Shanghai/Guangdong x three carriers
  upload  : ranking upload disabled by default
EOF
}

network_tools_menu() {
  require_root
  [[ -t 0 ]] || die "网络工具菜单需要 TTY。"
  while true; do
    echo
    echo "================ 网络调优 / TCP 测速 ================"
    cat <<'EOF'
  1. TCPFit 一键/交互调优（进入上游菜单，选 1 为一键调优）
  2. TCPFit 查看状态
  3. TCPFit 完整回滚
  4. TcpQuality IPv4 三网测速（北京/上海/广东，共 9 节点）
  5. TcpQuality IPv4 综合测试（丢包探测 + 三网测速）
  6. TcpQuality IPv4 三网回程线路
  7. TcpQuality 仅广东三网测速
  8. 查看固定版本 / 上游来源
  0. 返回
EOF
    local n
    read -r -p "请选择 [0-8]: " n
    case "$n" in
      1) network_tools_tcpfit || true ;;
      2) network_tools_tcpfit status || true ;;
      3)
        echo "将按 TCPFit 首次调优前快照回滚其全部改动。"
        if wizard_yesno "确认继续？" n; then network_tools_tcpfit rollback || true; fi
        ;;
      4) network_tools_tcpquality speed || true ;;
      5) network_tools_tcpquality full || true ;;
      6) network_tools_tcpquality route || true ;;
      7) network_tools_tcpquality gd || true ;;
      8) network_tools_info ;;
      0) return 0 ;;
      *) echo "输入无效。" ;;
    esac
    echo
    read -r -p "按 Enter 返回网络工具菜单..." _
  done
}
