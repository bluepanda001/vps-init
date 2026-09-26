#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
for f in vps-init $(find . -type f -name '*.sh' ! -path './verify/selftest.sh' | sort); do bash -n "$f"; done
python3 -m py_compile modules/3x-ui/xui_api.py modules/cloudflare/cloudflare.py modules/lucky/lucky_api.py
for p in base-only reality-only nginx-reality lucky-reality; do
  cfg=$(mktemp)
  cp config.env.example "$cfg"
  sed -i "s/^PROFILE=.*/PROFILE=\"$p\"/" "$cfg"
  if [[ "$p" == nginx-reality || "$p" == lucky-reality ]]; then sed -i 's/^ROOT_DOMAIN=.*/ROOT_DOMAIN="example.com"/' "$cfg"; fi
  ROOT_DIR="$ROOT_DIR" bash -c 'set -Eeuo pipefail; source "$ROOT_DIR/lib/common.sh"; source "$ROOT_DIR/lib/validate.sh"; load_config "$1"; validate_config' _ "$cfg"
  rm -f "$cfg"
done

# V1.1 defaults / wizard-generated config sanity.
ROOT_DIR="$ROOT_DIR" bash -c '''set -Eeuo pipefail
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/validate.sh"
source "$ROOT_DIR/lib/wizard.sh"
set_config_defaults
[[ "$XUI_PANEL_URI_PATH" == "/zhg/" ]]
[[ "$XUI_SUB_URI_PATH" == "/zhg/" ]]
W_PROFILE=reality-only
W_PROVIDER=racknerd
W_SERVER_NAME=test-vps
W_SSH_PORT=22
W_SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEtK4X4rx9lym+14EfW56+WF9l3h5mX3QMzDUhSQ5eWn test"
W_SSH_IDENTITY_HINT=id_ed25519_test
W_ROOT_DOMAIN=""
W_LE_EMAIL=""
W_REALITY_TARGET_MODE=auto
W_REALITY_TARGET=""
W_SUBSCRIPTION_PORT=2096
W_PANEL_PATH=/zhg/
W_SUB_PATH="/zhg/"
W_ENABLE_DOCKER=false
cfg=$(mktemp)
wizard_write_config "$cfg"
load_config "$cfg"
validate_config
[[ "$PROFILE" == reality-only ]]
[[ "$XUI_PANEL_URI_PATH" == /zhg/ ]]
[[ "$XUI_SUB_URI_PATH" == "/zhg/" ]]
rm -f "$cfg"
'''

# Clash/Mihomo standard subscription path and explicit Clash path must not be
# identical; current 3x-ui registers separate Gin routes for them.
grep -q 'subClashEnableRouting:true' modules/subscription/apply.sh
grep -q 'subClashAutoDetect:true' modules/subscription/apply.sh
grep -q 'subJsonEnable:false' modules/subscription/apply.sh
grep -q 'subClashPath:"/clash/"' modules/subscription/apply.sh

# Core rule: never install/use a second standalone Xray outside 3x-ui.
if grep -R --include='*.sh' --exclude='selftest.sh' -E 'XTLS/Xray-install|/usr/local/bin/xray' . >/dev/null; then
  echo 'FAIL: standalone Xray installer/path found in shell scripts' >&2; exit 1
fi
# No accidental 777 permissions.
if grep -R --include='*.sh' --exclude='selftest.sh' -E 'chmod[[:space:]]+(-R[[:space:]]+)?777' . >/dev/null; then
  echo 'FAIL: chmod 777 found' >&2; exit 1
fi
# Optional destructive reinstall entry must stay explicit and pinned.
grep -q 'bin456789/reinstall' lib/wizard.sh
grep -q '2bcbc96100fe733bf9a16d609f799246f62666e5' lib/wizard.sh
grep -q 'ubuntu 24.04 --minimal' lib/wizard.sh
grep -q '请输入大写 DD' lib/wizard.sh
grep -q 'reinstall.sh reset' lib/wizard.sh
echo 'SELFTEST_OK'
