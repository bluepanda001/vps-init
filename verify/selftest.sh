#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
for f in vps-init $(find . -type f -name '*.sh' ! -path './verify/selftest.sh' | sort); do
  echo "SYNTAX_CHECK $f"
  bash -n "$f"
done
python3 -m py_compile modules/3x-ui/xui_api.py modules/cloudflare/cloudflare.py modules/lucky/lucky_api.py optional/docker/merge_daemon.py verify/tests/test_lucky_behavior.py verify/tests/test_docker_merge.py
find modules -type d -name '__pycache__' -prune -exec rm -rf {} +
for p in base-only lucky-web reality-only nginx-reality lucky-reality; do
  cfg=$(mktemp)
  cp config.env.example "$cfg"
  sed -i "s/^PROFILE=.*/PROFILE=\"$p\"/" "$cfg"
  if [[ "$p" == nginx-reality || "$p" == lucky-reality || "$p" == lucky-web ]]; then sed -i 's/^ROOT_DOMAIN=.*/ROOT_DOMAIN="example.com"/' "$cfg"; fi
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
W_ENABLE_CF_WS=false
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
grep -q 'apt_get_with_lock_retry install -y -qq cron' modules/subscription/apply.sh
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
grep -Fq 'cmd=(bash "$script" ubuntu 24.04 --minimal --user root --ssh-port "$current_port")' lib/wizard.sh

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
# V1.2.6: Cloudflare CDN WS must be a real loopback Xray inbound behind
# Cloudflare-proxied DNS and an Nginx TLS/SNI frontend, with real proxy verification.
grep -q 'create-ws' modules/3x-ui/xui_api.py
grep -q -- '--proxied' modules/cloudflare/cloudflare.py
grep -q 'VPSINIT-CDN-WS' optional/cf-ws/apply.sh
grep -q '127.0.0.1:8444' optional/cf-ws/apply.sh
grep -q 'vps-init-extra-sni.map' modules/nginx/apply.sh
grep -q 'Cloudflare CDN WS end-to-end proxy' verify/verify.sh
grep -q 'Mihomo subscription advertises CDN WS endpoint' verify/verify.sh
grep -q 'W_ENABLE_CF_WS' lib/wizard.sh

# V1.2.7: REALITY fallback abuse protection, explicit Clash subscription,
# user-supplied panel credentials, and structured secrets output.
grep -q 'limitFallbackUpload' modules/3x-ui/xui_api.py
grep -q 'limitFallbackDownload' modules/3x-ui/xui_api.py
grep -q 'refusing high-risk Reality target' modules/3x-ui/xui_api.py
grep -q 'REALITY_FALLBACK_DOWNLOAD_BPS' modules/reality/apply.sh
grep -q 'SUBSCRIPTION_CLASH_URL' modules/subscription/apply.sh
grep -q 'SUBSCRIPTION_MIHOMO_URL' modules/subscription/apply.sh
grep -q 'VPSINIT_XUI_USERNAME_INPUT' modules/3x-ui/apply.sh
grep -q 'VPSINIT_LUCKY_USERNAME_INPUT' modules/lucky/apply.sh
grep -q 'wizard_collect_admin_credentials' lib/wizard.sh
grep -q 'vps-init secrets --raw' vps-init
grep -q '【一、3x-ui 面板】' vps-init

# V1.2.8: credentials changed through vps-init must update the live service,
# root-only state, and root-only secrets together.
grep -q 'source "$ROOT_DIR/lib/credentials.sh"' vps-init
grep -q 'vps-init passwd' vps-init
grep -q 'credential_change_xui' lib/credentials.sh
grep -q 'credential_change_lucky' lib/credentials.sh
grep -q 'state_set XUI_PASSWORD' lib/credentials.sh
grep -q 'secret_set XUI_PASSWORD' lib/credentials.sh
grep -q 'state_set LUCKY_PASSWORD' lib/credentials.sh
grep -q 'secret_set LUCKY_PASSWORD' lib/credentials.sh
grep -q '/opt/lucky/lucky -rResetUser' lib/credentials.sh
grep -q 'Authorization: Bearer' lib/credentials.sh
if grep -q 'XUI_PASSWORD=' config.env.example; then
  echo 'FAIL: panel passwords must not be stored in normal config.env' >&2; exit 1
fi
python3 - <<'PY_REALITY_SAFE'
from pathlib import Path
import importlib.util
s=Path("lib/common.sh").read_text()
assert "www.cloudflare.com" not in s.split('REALITY_CANDIDATES="',1)[1].split('"',1)[0]
spec=importlib.util.spec_from_file_location("xui_api","modules/3x-ui/xui_api.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.target_is_high_risk("www.cloudflare.com:443")
assert m.target_is_high_risk("foo.pages.dev:443")
assert not m.target_is_high_risk("dl.google.com:443")
try:
    m.select_target("", "", "manual", "www.cloudflare.com:443", "")
except RuntimeError as e:
    assert "high-risk" in str(e)
else:
    raise AssertionError("Cloudflare target was not rejected")
lim=m.fallback_limit(1024,2048,4096)
assert lim == {"afterBytes":1024,"bytesPerSec":2048,"burstBytesPerSec":4096}
PY_REALITY_SAFE

python3 - <<'PY_CFWS_ORDER'
from pathlib import Path
s=Path("vps-init").read_text()
assert s.index("module_nginx") < s.index("optional_cf_ws", s.index("if profile_has_xui"))
PY_CFWS_ORDER

# V1.3.x: Lucky is the graphical Web Gateway; 1.3.1 also supports
# a node-free Lucky Web Only profile and separates DD from normal setup.
grep -q 'Lucky + Reality - 图形化 Web Gateway' lib/wizard.sh
grep -q 'Lucky Web Only - Base + Docker + Lucky' lib/wizard.sh
grep -q '服务器公钥位置：/root/.ssh/authorized_keys' lib/wizard.sh
grep -q 'LUCKY_PANEL_SSH_TUNNEL' modules/lucky/apply.sh
grep -q 'configure-web-only' modules/lucky/lucky_api.py
grep -q 'vps-init gateway' vps-init
grep -q 'vps-init reinstall' vps-init
grep -q '当前 Gateway： Lucky Web Only（无节点）' vps-init
grep -q 'Lucky owns public 443' verify/verify.sh
grep -q 'lucky-web' core/firewall.sh
grep -q 'profile_has_lucky' lib/common.sh
grep -q 'Password|密码' lib/wizard.sh
if grep -q 'wizard_offer_reinstall' lib/wizard.sh; then
  echo 'FAIL: normal wizard must not ask for DD/reinstall' >&2; exit 1
fi
if [[ -d proxy || -d apps ]]; then
  echo 'FAIL: project must not ship a duplicate proxy center or app installers' >&2; exit 1
fi

ROOT_DIR="$ROOT_DIR" bash -c '''set -Eeuo pipefail
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/validate.sh"
set_config_defaults
PROFILE=lucky-web
ROOT_DOMAIN=example.com
ENABLE_DOCKER=true
ENABLE_CF_WS=false
resolve_auto_settings
validate_config
[[ "$ENABLE_SUBSCRIPTION_RESOLVED" == false ]]
[[ "$LUCKY_DOMAIN" == lucky.example.com ]]
profile_has_domain
profile_has_lucky
! profile_has_xui
'''

grep -q 'SSH 密钥验证：' core/ssh.sh
grep -q '还没测试 / 测试失败' core/ssh.sh
grep -q '不会退出当前部署' core/ssh.sh
if grep -q '尚未确认密钥登录。当前会话不要关闭；确认后重新运行即可' core/ssh.sh; then
  echo 'FAIL: SSH verification must retry in place instead of aborting the wizard' >&2; exit 1
fi
grep -q 'https://dash.cloudflare.com/profile/api-tokens' modules/cloudflare/apply.sh
grep -q 'Edit zone DNS 模板' modules/cloudflare/apply.sh
grep -q '检测到 Lucky 初始默认凭据' modules/lucky/apply.sh
grep -q -- '--user "666" --password "666" status' modules/lucky/apply.sh
grep -q 'Runtime -rResetUser is only a last-resort recovery path' modules/lucky/apply.sh
grep -q 'for _ in $(seq 1 10)' modules/lucky/apply.sh
grep -q 'LUCKY_SAFE_URL="${LUCKY_SAFE_URL:-zhg}"' modules/lucky/apply.sh
grep -q -- '-setconf -key SetSafeURL -value "$LUCKY_SAFE_URL"' modules/lucky/apply.sh
grep -q 'secret_set LUCKY_SAFE_URL' modules/lucky/apply.sh
grep -q 'secret_line "安全入口" LUCKY_SAFE_URL' vps-init
grep -q 'Lucky SafeURL' verify/verify.sh
grep -q 'https://${LUCKY_DOMAIN}/${LUCKY_SAFE_URL:-zhg}' vps-init
python3 verify/tests/test_lucky_behavior.py
python3 verify/tests/test_docker_merge.py
bash verify/tests/test_shell_behaviors.sh
python3 verify/tests/test_ssh_rollback.py

# Stability v1.3.6: behavioral regression coverage and safety boundaries.
grep -q 'systemd-run --quiet --unit=' core/ssh.sh
grep -q 'render_ssh_stage_config' core/ssh.sh
grep -q 'VPSINIT_VERSION=' vps-init
grep -q 'vps-init upgrade-system' vps-init
if grep -q 'rm -f "$token_file"' modules/cloudflare/apply.sh; then
  echo 'FAIL: Cloudflare validation must not delete the saved token before replacement' >&2
  exit 1
fi
grep -q 'cert_has_ip_san "$cert" "$SERVER_IP"' modules/subscription/apply.sh
grep -q 'cert_key_match "$cert" "$key"' modules/subscription/apply.sh
[[ "$(tr -d "[:space:]" < VERSION)" == "1.3.14" ]]
grep -q 'permitrootlogin_matches_expected' core/ssh.sh
grep -q 'systemctl reset-failed ssh.service ssh.socket' core/ssh.sh
grep -q 'ssh_rollback_unit_name' core/ssh.sh
grep -q 'clear_ssh_rollback_marker' core/ssh.sh
grep -q 'apt_get_with_lock_retry()' lib/common.sh
grep -q '/var/cache/apt/archives/lock' lib/common.sh
grep -q 'apt_get_with_lock_retry install -y docker-ce' optional/docker/apply.sh
python3 - <<'PY_APT_LOCK'
from pathlib import Path
import re
bad=[]
for root in ("core","modules","optional"):
    for p in Path(root).rglob("*.sh"):
        for n,line in enumerate(p.read_text().splitlines(),1):
            if re.match(r'^\s*apt-get\b', line) or re.match(r'^\s*[A-Z_][A-Z0-9_]*=[^ ]+\s+apt-get\b', line):
                bad.append(f"{p}:{n}:{line.strip()}")
assert not bad, "direct apt-get bypasses lock retry:\n" + "\n".join(bad)
PY_APT_LOCK
grep -q 'CertificateRemarkNameConflict' modules/lucky/lucky_api.py
grep -q '16601/${safe}/version' lib/common.sh
grep -q 'lucky_api() {' lib/common.sh
grep -q 'lucky_local_version_ok 3 || die "Lucky 后台未启动。"' modules/lucky/apply.sh
grep -q 'lucky_api --user' modules/lucky/apply.sh
if grep -q 'http://127.0.0.1:16601/version' modules/lucky/apply.sh; then
  echo 'FAIL: Lucky startup must follow the safe URL when it is already set' >&2
  exit 1
fi
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

# V1.2.5: Lucky + Reality must front REALITY with Nginx Stream. REALITY sends
# unauthenticated/non-REALITY TLS to target, so Xray-side fallback cannot expose Lucky.
grep -q 'nginx-reality|lucky-reality) listen="127.0.0.1"; port=1443' modules/reality/apply.sh
grep -q '\[\[ "$PROFILE" == "nginx-reality" || "$PROFILE" == "lucky-reality" \]\]' modules/nginx/apply.sh
grep -q 'Reality -> 1443，普通 HTTPS -> Lucky 8443' modules/nginx/apply.sh
! grep -q 'fallback="127.0.0.1:8443"' modules/reality/apply.sh
echo 'SELFTEST_OK'
