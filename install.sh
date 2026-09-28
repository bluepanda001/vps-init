#!/usr/bin/env bash
set -Eeuo pipefail

# Default public repository for this published build.
REPO_DEFAULT="bluepanda001/vps-init"
REPO="${VPSINIT_REPO:-$REPO_DEFAULT}"
BOOTSTRAP_REF="${VPSINIT_BOOTSTRAP_REF:-main}"
INSTALL_DIR="/opt/vps-init"
BIN_LINK="/usr/local/bin/vps-init"
NO_MENU=false
UPDATE=false

for arg in "$@"; do
  case "$arg" in
    --no-menu) NO_MENU=true ;;
    --update) UPDATE=true ;;
    -h|--help)
      cat <<'TXT'
VPS Init bootstrap

Environment:
  VPSINIT_REPO=owner/repo        Override GitHub repository.
  VPSINIT_BOOTSTRAP_REF=main     Source ref used only before the first formal Release exists.

Options:
  --update     Replace program files while preserving /opt/vps-init/config.env.
  --no-menu    Do not open the interactive menu after installation.
TXT
      exit 0
      ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] 请使用 root 运行。" >&2; exit 1; }
if [[ -z "$REPO" || "$REPO" != */* ]]; then
  cat >&2 <<'TXT'
[ERROR] GitHub 仓库来源无效。
可临时覆盖来源：
  VPSINIT_REPO=owner/repo bash install.sh
TXT
  exit 2
fi

log() { printf '[VPS-INIT] %s\n' "$*"; }
die() { printf '[VPS-INIT][ERROR] %s\n' "$*" >&2; exit 1; }

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates tar
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
src=""
version=""
RELEASE_LOOKUP_STATUS=""
RELEASE_LOOKUP_TAG=""

# Determine whether a stable Release exists without relying on api.github.com.
# GitHub's /releases/latest page redirects to /releases/tag/<tag> when a
# stable Release exists and returns 404 when the repository has none.
#
# IMPORTANT: only an explicit 404 is treated as "no Release". DNS/TLS/network
# errors, rate limiting, 403, 5xx, an unexpected 200 page, or an invalid tag
# are lookup failures and MUST NOT fall back to unverified source.
resolve_latest_release() {
  local endpoint meta http effective tag
  endpoint="https://github.com/${REPO}/releases/latest"

  if ! meta="$(curl -sS -L       --retry 3 --retry-delay 2       --connect-timeout 10 --max-time 60       -o /dev/null -w '%{http_code}\n%{url_effective}\n'       "$endpoint")"; then
    RELEASE_LOOKUP_STATUS="error"
    return 1
  fi

  http="$(printf '%s\n' "$meta" | sed -n '1p')"
  effective="$(printf '%s\n' "$meta" | sed -n '2p')"

  case "$http" in
    200)
      tag="$(printf '%s\n' "$effective" | sed -n 's#^.*/releases/tag/\([^/?#]*\).*$#\1#p')"
      if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        RELEASE_LOOKUP_STATUS="found"
        RELEASE_LOOKUP_TAG="$tag"
        return 0
      fi
      RELEASE_LOOKUP_STATUS="error"
      return 1
      ;;
    404)
      RELEASE_LOOKUP_STATUS="none"
      RELEASE_LOOKUP_TAG=""
      return 0
      ;;
    *)
      RELEASE_LOOKUP_STATUS="error"
      return 1
      ;;
  esac
}

download_release() {
  local tag="$1" ver archive base sumline expected listed
  ver="${tag#v}"
  archive="vps-init-${ver}.tar.gz"
  base="https://github.com/${REPO}/releases/download/${tag}"
  log "尝试下载正式 Release：${tag}"

  curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 180     -o "$tmp/$archive" "$base/$archive" || return 1
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60     -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || return 1

  sumline="$(grep -E "[[:space:]]+[*]?${archive//./\\.}$" "$tmp/SHA256SUMS" | head -1 || true)"
  [[ -n "$sumline" ]] || return 1
  expected="$(awk '{print $1}' <<<"$sumline")"
  listed="$(awk '{print $2}' <<<"$sumline")"
  listed="${listed#\*}"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "$listed" == "$archive" ]] || return 1
  (cd "$tmp" && printf '%s  %s\n' "$expected" "$archive" | sha256sum -c -) || return 1

  mkdir -p "$tmp/release"
  tar -xzf "$tmp/$archive" -C "$tmp/release"
  if [[ -x "$tmp/release/vps-init/vps-init" ]]; then
    src="$tmp/release/vps-init"
  elif [[ -x "$tmp/release/vps-init" ]]; then
    src="$tmp/release"
  else
    src="$(find "$tmp/release" -maxdepth 3 -type f -name vps-init -perm -111 -printf '%h\n' | head -1 || true)"
  fi
  [[ -n "$src" && -x "$src/vps-init" ]] || return 1
  version="$ver"
  return 0
}

download_source_ref() {
  local ref="$1" kind url root
  log "仓库明确没有正式 Release；回退下载首次发布前源码：${REPO}@${ref}"
  for kind in heads tags; do
    url="https://codeload.github.com/${REPO}/tar.gz/refs/${kind}/${ref}"
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 180       -o "$tmp/source.tar.gz" "$url" 2>/dev/null; then
      rm -rf "$tmp/source"
      mkdir -p "$tmp/source"
      tar -xzf "$tmp/source.tar.gz" -C "$tmp/source"
      root="$(find "$tmp/source" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
      if [[ -n "$root" && -x "$root/vps-init" ]]; then
        src="$root"
        version="$(cat "$root/VERSION" 2>/dev/null || printf '%s' "$ref")"
        return 0
      fi
    fi
  done
  return 1
}

if ! resolve_latest_release; then
  die "无法可靠确定 GitHub 最新 Release（网络/HTTP 状态/重定向异常）。为避免执行未校验源码，已停止；不会回退到 ${BOOTSTRAP_REF}。"
fi

case "$RELEASE_LOOKUP_STATUS" in
  found)
    tag="$RELEASE_LOOKUP_TAG"
    download_release "$tag" ||       die "发现正式 Release ${tag}，但下载或 SHA256 校验失败。为避免执行未校验源码，已拒绝回退到 ${BOOTSTRAP_REF}。"
    ;;
  none)
    log "GitHub 明确返回：仓库暂无正式 Release。仅首次发布前允许源码回退。"
    download_source_ref "$BOOTSTRAP_REF" ||       die "无法从 GitHub 下载首次发布前源码。请检查仓库是否公开、网络是否正常。"
    ;;
  *)
    die "Release 探测进入未知状态：${RELEASE_LOOKUP_STATUS:-empty}。为安全起见已停止。"
    ;;
esac

[[ -x "$src/vps-init" ]] || die "下载内容不完整：缺少 vps-init。"
log "下载完成：VPS Init ${version:-unknown}"

stage="${INSTALL_DIR}.new.$$"
backup_root="/var/backups/vps-init-bootstrap"
backup_dir="${backup_root}/$(date -u '+%Y%m%dT%H%M%SZ')"
rm -rf "$stage"
mkdir -p "$stage"
tar -C "$src" --exclude='.git' --exclude='config.env' --exclude='__pycache__' --exclude='*.pyc' --exclude='*.pyo' -cf - . |   tar -C "$stage" -xf -
chmod +x "$stage/vps-init" "$stage/install.sh" 2>/dev/null || true
find "$stage" -type f -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true

# Preserve the user's local configuration across updates.
if [[ -f "$INSTALL_DIR/config.env" ]]; then
  install -m 600 "$INSTALL_DIR/config.env" "$stage/config.env"
fi

cat > "$stage/.source.env" <<EOF2
VPSINIT_REPO=$(printf '%q' "$REPO")
VPSINIT_BOOTSTRAP_REF=$(printf '%q' "$BOOTSTRAP_REF")
EOF2
chmod 600 "$stage/.source.env"

if [[ -d "$INSTALL_DIR" ]]; then
  mkdir -p "$backup_dir"
  cp -a "$INSTALL_DIR" "$backup_dir/vps-init" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
fi
mv "$stage" "$INSTALL_DIR"
ln -sfn "$INSTALL_DIR/vps-init" "$BIN_LINK"

log "已安装到 $INSTALL_DIR"
log "命令：vps-init"
[[ -d "$backup_dir/vps-init" ]] && log "旧程序备份：$backup_dir/vps-init"

if [[ "$NO_MENU" == true ]]; then
  exit 0
fi

# Re-open the controlling terminal, so both `bash <(curl ...)` and
# `curl ... | bash` can still enter the interactive wizard when a TTY exists.
if [[ -r /dev/tty && -w /dev/tty ]]; then
  if [[ -f "$INSTALL_DIR/config.env" || -f /var/lib/vps-init/state.env ]]; then
    exec "$BIN_LINK" menu </dev/tty >/dev/tty 2>&1
  else
    exec "$BIN_LINK" wizard </dev/tty >/dev/tty 2>&1
  fi
fi

log "当前没有可用交互 TTY。稍后登录 VPS 后直接运行：vps-init"
