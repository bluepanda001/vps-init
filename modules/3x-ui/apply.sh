#!/usr/bin/env bash
xui_base_url() { printf 'http://127.0.0.1:%s%s' "$XUI_PANEL_PORT" "$XUI_WEB_BASE_PATH"; }

xui_release_sha256() {
  # GitHub Release asset digests for MHSanaei/3x-ui v3.8.5.
  # These are project-pinned so replacing both an upstream asset and its
  # sidecar checksum cannot silently change what runs as root.
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' '6a85c110a04a727613c933c54ae602b8d37dab8876c6e20a6d46623010dd9d3c' ;;
    i386|i486|i586|i686|x86) printf '%s\n' 'f13691655dc274479ebbdd1cba5eb32c978728df2457c0b73f9f687a0eca09ac' ;;
    aarch64|arm64|armv8|armv8*) printf '%s\n' '2dd601a32426fb19b0eafdffaead374a9cdb66be4dfb39407f9f50fa4e7234e7' ;;
    armv7|armv7l) printf '%s\n' '2f19d148b05611c3245f50cbad24b9bb13cf52754981ee2a4fc24cc332402473' ;;
    armv6|armv6l) printf '%s\n' 'b01518d413086caef719f29f7c81c15dbeec0939cc55a4bf63a1d4edcdb94dea' ;;
    armv5|armv5l) printf '%s\n' 'fe90376169675d40f5e3e67364b1b157e38f16441c41b01023e20fc79a7c5d2d' ;;
    s390x) printf '%s\n' 'f5fc7593c35c3135f7e905f77c727a2a5becea3880273255ab57a62430441148' ;;
    *) return 1 ;;
  esac
}

prepare_pinned_xui_installer() {
  local installer="$1" commit="$2"

  # The v3.8.5 annotated tag currently points at this reviewed commit. Fetch the
  # installer and follow-up repository files by immutable commit, not by tag.
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60     "https://raw.githubusercontent.com/MHSanaei/3x-ui/${commit}/install.sh"     -o "$installer" || die "下载固定提交的 3x-ui 安装脚本失败。"

  # The pinned upstream installer already validates the release sidecar. Add a
  # second, project-owned digest check and force x-ui.sh/service-file downloads
  # to the immutable commit as well.
  python3 - "$installer" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

checksum_line = '    actual=$(sha256sum "${file}" | awk \'{print $1}\')\n'
if s.count(checksum_line) != 1:
    raise SystemExit("unexpected 3x-ui installer checksum function")
extra = checksum_line + r'''    if [[ -n "${VPSINIT_XUI_EXPECTED_SHA256:-}" && "${tag_version:-}" == "v3.8.5" ]]; then
        if [[ "${actual}" != "${VPSINIT_XUI_EXPECTED_SHA256}" ]]; then
            rm -f "${file}"
            echo -e "${red}Project-pinned checksum mismatch for $(basename "${file}"): expected ${VPSINIT_XUI_EXPECTED_SHA256}, got ${actual}${plain}"
            exit 1
        fi
        echo -e "${green}Project-pinned checksum verified: ${actual}${plain}"
    fi
'''
s = s.replace(checksum_line, extra, 1)

old_ref = '    local script_ref="${tag_version}"\n'
new_ref = '    local script_ref="${VPSINIT_XUI_SCRIPT_REF:-${tag_version}}"\n'
if s.count(old_ref) != 1:
    raise SystemExit("unexpected 3x-ui installer script_ref assignment")
s = s.replace(old_ref, new_ref, 1)

p.write_text(s)
PY

  grep -q 'Project-pinned checksum mismatch' "$installer" || die "3x-ui 安装脚本完整性补丁未成功写入。"
  grep -q 'VPSINIT_XUI_SCRIPT_REF' "$installer" || die "3x-ui 固定提交补丁未成功写入。"
  chmod 700 "$installer"
}

module_xui() {
  command_exists python3 || die "python3 missing"

  local want_ver="3.8.5"
  local installer_commit="7ef22f94c950ff09f0870e2295fa65ad5968742c"
  local expected_archive_sha have_ver=""
  expected_archive_sha="$(xui_release_sha256)" || die "3x-ui v${want_ver} 暂无当前架构 $(uname -m) 的项目固定 SHA256。"

  if [[ -x /usr/local/x-ui/x-ui ]]; then
    have_ver="$(/usr/local/x-ui/x-ui -v 2>/dev/null | tr -d '[:space:]' || true)"
  fi

  if [[ ! -x /usr/local/x-ui/x-ui || "$have_ver" != "$want_ver" ]]; then
    if [[ -n "$have_ver" ]]; then
      log_info "3x-ui 当前版本 ${have_ver}，切换到项目固定版本 ${want_ver}。"
    else
      log_info "安装官方 3x-ui ${want_ver}（安装器固定 commit + release archive 固定 SHA256）。"
    fi

    prepare_pinned_xui_installer /tmp/3x-ui-install.sh "$installer_commit"

    VPSINIT_XUI_EXPECTED_SHA256="$expected_archive_sha"     VPSINIT_XUI_SCRIPT_REF="$installer_commit"     XUI_NONINTERACTIVE=1     XUI_SSL_MODE=none     DEBIAN_FRONTEND=noninteractive       bash /tmp/3x-ui-install.sh "v${want_ver}"

    rm -f /tmp/3x-ui-install.sh
  else
    log_info "3x-ui ${have_ver} 已安装，复用。"
  fi

  [[ -x /usr/local/x-ui/x-ui ]] || die "3x-ui 安装后未找到 /usr/local/x-ui/x-ui"
  have_ver="$(/usr/local/x-ui/x-ui -v 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$have_ver" == "$want_ver" ]] || die "3x-ui 版本校验失败：当前 ${have_ver:-unknown}，需要 ${want_ver}。"

  state_load
  XUI_PANEL_PORT="${XUI_PANEL_PORT:-$(random_port)}"
  # Backward compatible: an existing state value always wins. On a fresh VPS,
  # use the user-facing panel URI configured by the wizard/config (default /zhg/).
  if [[ -z "${XUI_WEB_BASE_PATH:-}" ]]; then
    XUI_WEB_BASE_PATH="${XUI_PANEL_URI_PATH:-/zhg/}"
  fi
  XUI_WEB_BASE_PATH="$(normalize_path "$XUI_WEB_BASE_PATH")"
  XUI_USERNAME="${XUI_USERNAME:-vpsadmin_$(random_hex 3)}"
  XUI_PASSWORD="${XUI_PASSWORD:-$(random_b64url 36 28)}"

  /usr/local/x-ui/x-ui setting     -port "$XUI_PANEL_PORT"     -username "$XUI_USERNAME"     -password "$XUI_PASSWORD"     -webBasePath "$XUI_WEB_BASE_PATH"     -listenIP 127.0.0.1 >/dev/null

  systemctl enable --now x-ui
  systemctl restart x-ui
  sleep 2

  local token_out
  token_out=$(/usr/local/x-ui/x-ui setting -getApiToken -tokenName vps-init 2>/dev/null)
  XUI_API_TOKEN="$(printf '%s\n' "$token_out" | awk -F'apiToken: ' '/apiToken:/{print $2}' | tail -1 | tr -d '[:space:]')"
  [[ -n "$XUI_API_TOKEN" ]] || die "无法生成 3x-ui API Token。"

  state_set XUI_PANEL_PORT "$XUI_PANEL_PORT"
  state_set XUI_WEB_BASE_PATH "$XUI_WEB_BASE_PATH"
  state_set XUI_USERNAME "$XUI_USERNAME"
  state_set XUI_PASSWORD "$XUI_PASSWORD"
  state_set XUI_API_TOKEN "$XUI_API_TOKEN"
  state_set XUI_VERSION "$have_ver"
  secret_set XUI_USERNAME "$XUI_USERNAME"
  secret_set XUI_PASSWORD "$XUI_PASSWORD"
  secret_set XUI_PANEL_SSH_TUNNEL "ssh -L ${XUI_PANEL_PORT}:127.0.0.1:${XUI_PANEL_PORT} -p ${SSH_PORT} root@${SERVER_IP}"
  secret_set XUI_PANEL_LOCAL_URL "http://127.0.0.1:${XUI_PANEL_PORT}${XUI_WEB_BASE_PATH}"
  secret_set XUI_API_TOKEN "$XUI_API_TOKEN"

  local api
  api="$(xui_base_url)"
  for _ in $(seq 1 15); do
    if curl -fsS --max-time 2 -H "Authorization: Bearer ${XUI_API_TOKEN}" "${api}panel/api/server/status" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  curl -fsS --max-time 5 -H "Authorization: Bearer ${XUI_API_TOKEN}" "${api}panel/api/server/status" >/dev/null ||     die "3x-ui 本地 API 不可用。"

  local xray=/usr/local/x-ui/bin/xray-linux-amd64
  [[ -x "$xray" ]] || xray="$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray*' -perm -111 | head -1 || true)"
  [[ -n "$xray" && -x "$xray" ]] || die "未找到 3x-ui 自带 Xray。"
  XUI_XRAY_BIN="$xray"
  state_set XUI_XRAY_BIN "$XUI_XRAY_BIN"
  log_ok "3x-ui ${have_ver} 已配置为 loopback-only；Xray 使用 3x-ui 自带版本。"
}
