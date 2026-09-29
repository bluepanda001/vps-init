#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
for f in vps-init $(find . -type f -name '*.sh' ! -path './verify/selftest.sh' | sort); do bash -n "$f"; done
python3 -m py_compile modules/3x-ui/xui_api.py modules/cloudflare/cloudflare.py modules/lucky/lucky_api.py
find modules -type d -name '__pycache__' -prune -exec rm -rf {} +
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
# Safety regressions fixed in V1.2.1/V1.2.2/V1.2.3/V1.2.4.
grep -q 'systemctl daemon-reload' core/ssh.sh
grep -q 'systemctl restart ssh.socket' core/ssh.sh
grep -q 'SSH_VERIFIED_PORT' core/ssh.sh
grep -q '00-00-vps-init.conf' core/ssh.sh
grep -q 'verify_root_key_policy' core/ssh.sh
grep -q 'PermitRootLogin prohibit-password' core/ssh.sh
grep -q 'vps-main-ed25519' core/ssh.sh
grep -q 'Netcatty 统一 SSH 规范' core/ssh.sh
grep -q 'vps-main-ed25519' lib/wizard.sh
grep -q '每台 VPS 单独 Identity' core/ssh.sh
if grep -q 'id_ed25519_.*provider' lib/wizard.sh; then
  echo 'FAIL: wizard must not generate one SSH private key per VPS/provider' >&2; exit 1
fi
grep -q 'SSH IPv4 listener on' verify/verify.sh
if grep -q 'ufw --force reset' core/firewall.sh; then
  echo 'FAIL: firewall apply must preserve non-vps-init rules' >&2; exit 1
fi
if grep -q 'state_set DEPLOYED_PROFILE' core/preflight.sh; then
  echo 'FAIL: preflight must not claim a deployed profile' >&2; exit 1
fi
grep -q 'state_set DEPLOYED_PROFILE' vps-init
if grep -q '"uuid":uuid,"publicKey":pub,"privateKey":priv' modules/3x-ui/xui_api.py; then
  echo 'FAIL: Reality private key is exposed in helper output' >&2; exit 1
fi
grep -q -- '--with-stream_ssl_preread_module' modules/nginx/apply.sh
if grep -R --exclude='selftest.sh' -q 'libnginx-mod-stream-ssl-preread' .; then
  echo 'FAIL: nonexistent Ubuntu dependency referenced' >&2; exit 1
fi
if grep -q "printf '\\\\n\\\\n\\\\n" modules/subscription/apply.sh; then
  echo 'FAIL: IP certificate issuance still depends on prompt piping' >&2; exit 1
fi
grep -q -- '--certificate-profile shortlived' modules/subscription/apply.sh

# V1.2.3: bootstrap may fall back to source only after an explicit "no Release"
# result. Lookup/network/HTTP ambiguity must fail closed.
grep -q 'RELEASE_LOOKUP_STATUS="none"' install.sh
grep -q '仓库尚无正式 Release' README.md
grep -q '无法可靠确定 GitHub 最新 Release' install.sh
if grep -q 'resolve_latest_release || true' install.sh; then
  echo 'FAIL: Release lookup errors must not be collapsed into "no Release"' >&2; exit 1
fi
if grep -q 'api.github.com/repos/${REPO}/releases/latest' install.sh; then
  echo 'FAIL: bootstrap should not depend on rate-limited releases/latest API discovery' >&2; exit 1
fi

# V1.2.3: DD must preserve all unique root ED25519 keys, with vps-main first,
# by using the pinned reinstall script's repeatable --ssh-key option.
grep -q 'wizard_existing_ed25519_keys' lib/wizard.sh
grep -q 'mapfile -t existing_keys' lib/wizard.sh
grep -q 'cmd+=(--ssh-key "$key")' lib/wizard.sh
grep -q '\$NF=="vps-main"' lib/wizard.sh

# V1.2.3: short-lived IP certificates must have a verified renewal mechanism.
grep -q 'apt-get install -y -qq cron' modules/subscription/apply.sh
grep -q 'systemctl enable --now cron' modules/subscription/apply.sh
grep -q -- '--install-cronjob' modules/subscription/apply.sh
grep -q "acme\\.sh.*--cron" modules/subscription/apply.sh
if grep -E -- '--install-cronjob.*\|\|[[:space:]]*true' modules/subscription/apply.sh >/dev/null; then
  echo 'FAIL: acme.sh cron installation failure must not be ignored' >&2; exit 1
fi

# V1.2.3: release archives/persistent copies must not contain generated bytecode.
grep -q -- "--exclude '__pycache__'" .github/workflows/release.yml
grep -q -- "--exclude '\*.pyc'" .github/workflows/release.yml
grep -q -- "--exclude='\*.pyc'" lib/common.sh

# Exercise the local 3x-ui installer patch against the exact two upstream
# lines it is designed to harden. This catches syntax/quoting drift without
# downloading or executing the real root installer in CI.
die() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck disable=SC1091
source modules/3x-ui/apply.sh
xui_patch_fixture="$(mktemp)"
cat > "$xui_patch_fixture" <<'EOF_XUI_PATCH'
    actual=$(sha256sum "${file}" | awk '{print $1}')
    local script_ref="${tag_version}"
EOF_XUI_PATCH
patch_pinned_xui_installer "$xui_patch_fixture"
grep -q 'Project-pinned checksum mismatch' "$xui_patch_fixture"
grep -q 'VPSINIT_XUI_SCRIPT_REF' "$xui_patch_fixture"
rm -f "$xui_patch_fixture"

# V1.2.3: 3x-ui installer repository content is immutable-commit pinned and
# release archives are independently pinned by project-owned digests.
grep -q '7ef22f94c950ff09f0870e2295fa65ad5968742c' modules/3x-ui/apply.sh
grep -q '6a85c110a04a727613c933c54ae602b8d37dab8876c6e20a6d46623010dd9d3c' modules/3x-ui/apply.sh
grep -q '2dd601a32426fb19b0eafdffaead374a9cdb66be4dfb39407f9f50fa4e7234e7' modules/3x-ui/apply.sh
grep -q 'Project-pinned checksum mismatch' modules/3x-ui/apply.sh
grep -q 'VPSINIT_XUI_SCRIPT_REF' modules/3x-ui/apply.sh
if grep -q 'raw.githubusercontent.com/MHSanaei/3x-ui/v3.8.5/install.sh' modules/3x-ui/apply.sh; then
  echo 'FAIL: 3x-ui installer must not be fetched through a movable tag' >&2; exit 1
fi

# V1.2.4: DD must be fully non-interactive for the target Linux username.
grep -Fq 'cmd=(bash "$script" ubuntu 24.04 --minimal --user root)' lib/wizard.sh

# V1.2.5: Lucky 2.27.2 uses encrypted/modular *.lkcf files. Bootstrap
# must use the documented runtime reset and authenticated API rather than
# editing encrypted config files or relying on unsupported offline setconf.
grep -q 'ExecStart=/opt/lucky/lucky -cd /opt/lucky' modules/lucky/apply.sh
grep -q 'systemctl start lucky' modules/lucky/apply.sh
grep -q 'AllowInternetaccess.*False' modules/lucky/lucky_api.py
if grep -q '/opt/lucky/lucky.conf' modules/lucky/apply.sh; then
  echo 'FAIL: Lucky 2.27.2 must not treat lucky.conf as plaintext config' >&2; exit 1
fi
if grep -q 'load_local_admin\|ensure-admin' modules/lucky/lucky_api.py modules/lucky/apply.sh; then
  echo 'FAIL: obsolete Lucky plaintext-config bootstrap remains' >&2; exit 1
fi

grep -q '拒绝回退' install.sh
[[ "$(tr -d '[:space:]' < VERSION)" == "1.2.5" ]]
# Optional destructive reinstall entry must stay explicit and pinned.
grep -q 'bin456789/reinstall' lib/wizard.sh
grep -q '2bcbc96100fe733bf9a16d609f799246f62666e5' lib/wizard.sh
grep -q 'ubuntu 24.04 --minimal --user root' lib/wizard.sh
grep -q '请输入大写 DD' lib/wizard.sh
grep -q 'reinstall.sh reset' lib/wizard.sh

# V1.2.5: wizard Profile migrations are transactional at the config-file level.
grep -q '失败迁移残留：443 当前由 Xray 占用' vps-init
grep -q '尝试自动恢复上一个已验证 Profile' lib/wizard.sh
grep -q 'VPSINIT_ALLOW_PROFILE_SWITCH=1.*apply.*backup' lib/wizard.sh
grep -q 'config.env.pending' lib/wizard.sh
grep -q '原有已验证配置未被候选配置覆盖' lib/wizard.sh
python3 - <<'PY_CONFIG_TXN'
from pathlib import Path
s=Path("vps-init").read_text()
assert 'resolve_runtime_ports\npersist_config "$cfg"\ncore_swap' not in s
verify=s.index('if verify_all; then')
persist=s.index('persist_config "$cfg"', verify)
state=s.index('state_set DEPLOYED_PROFILE "$PROFILE"', verify)
assert verify < persist < state
PY_CONFIG_TXN

# V1.2.5: Lucky 2.27.2 current frontend requires an anti-replay nonce and
# uses Lucky-Admin-Token instead of Authorization for authenticated API calls.
grep -q 'def lucky_nonce' modules/lucky/lucky_api.py
grep -q 'Lucky-Admin-Token' modules/lucky/lucky_api.py
grep -q "'TwoFA':''" modules/lucky/lucky_api.py

# V1.2.5: Lucky 2.27.2 recovery uses documented runtime reset, without -cd,
# then immediately rotates away from the default account through the API.
grep -q '/opt/lucky/lucky -rResetUser' modules/lucky/apply.sh
! grep -q -- '-rResetUser .* -cd' modules/lucky/apply.sh
! grep -q -- '-setconf -key AdminAccount' modules/lucky/apply.sh
grep -q -- '--user "666" --password "666" set-admin' modules/lucky/apply.sh
echo 'SELFTEST_OK'
