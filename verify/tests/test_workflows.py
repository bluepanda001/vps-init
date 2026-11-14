"""Behavioral tests: no real package, service, firewall or disk operations."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Workflows(unittest.TestCase):
    def run_sh(self, script, code=0):
        with tempfile.TemporaryDirectory() as td:
            env = os.environ | {"TD": td, "REPO": str(ROOT)}
            result = subprocess.run(["bash", "-c", '''set -Eeuo pipefail
cd "$REPO"
source lib/common.sh
source lib/validate.sh
source lib/wizard.sh
source lib/deployment.sh
source lib/app/deploy.sh
STATE_DIR="$TD/state"; STATE_FILE="$STATE_DIR/state.env"
PERSIST_DIR="$TD/install"; SECRETS_FILE="$TD/secrets"
mkdir -p "$STATE_DIR" "$PERSIST_DIR"
''' + script], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, code, result.stdout + result.stderr)
            return result

    def test_selection_retries_and_leading_zero(self):
        self.run_sh('[[ "$(wizard_select test one two <<< $\'bad\\n08\\n2\')" == 2 ]]')

    def test_selection_eof_cancels(self):
        self.run_sh('wizard_select test one </dev/null', 10)

    def test_selection_zero_cancels(self):
        self.run_sh('wizard_select test one <<< 0', 10)

    def test_eof_never_confirms(self):
        self.run_sh('if wizard_yesno dangerous y </dev/null; then exit 99; fi')

    def test_state_roundtrip_and_atomic_replacement(self):
        self.run_sh('''state_set REALITY_UUID stable
ln "$STATE_FILE" "$TD/old-state"
state_set REALITY_UUID unchanged
grep -qx REALITY_UUID=stable "$TD/old-state"
state_load
[[ "$REALITY_UUID" == unchanged ]]
secret_set TOKEN 'secret $literal'
secret_set TOKEN 'next value'
[[ $(wc -l < "$SECRETS_FILE") -eq 1 ]]
''')

    def test_config_commit_preserves_tunables_removes_only_inputs(self):
        self.run_sh('''printf '%s\n' 'PROFILE=base-only' 'CUSTOM=value' 'VPSINIT_APT_LOCK_TIMEOUT=90' 'VPSINIT_XUI_PASSWORD_INPUT=secret' 'VPSINIT_ALLOW_PROFILE_SWITCH=1' > "$PERSIST_DIR/config.env"
persist_config "$PERSIST_DIR/config.env"
grep -qx CUSTOM=value "$PERSIST_DIR/config.env"
grep -qx VPSINIT_APT_LOCK_TIMEOUT=90 "$PERSIST_DIR/config.env"
! grep -q PASSWORD_INPUT "$PERSIST_DIR/config.env"
! grep -q ALLOW_PROFILE_SWITCH "$PERSIST_DIR/config.env"
''')

    def test_base_only_does_not_stop_user_services(self):
        self.run_sh('''PREVIOUS_DEPLOYED_PROFILE=base-only
PROFILE=base-only
systemctl() { exit 99; }
prepare_profile_transition
''')

    def test_failed_step_does_not_continue_even_if_last_command_succeeds(self):
        r = self.run_sh('''PROFILE=base-only
trap 'rc=$?; [[ ! -f "$TD/unsafe" ]]; grep -q STEP=broken "$STATE_DIR/deployment.env"; exit "$rc"' EXIT
broken() { false; touch "$TD/unsafe"; }
deployment_step broken
''', 1)
        self.assertNotIn('secret', r.stderr)

    def test_all_profile_pipelines_and_repeated_apply(self):
        self.run_sh('''source lib/app/display.sh
flock() { :; } # only the platform lock is mocked; no host files are used
show_info_summary() { :; }
for fn in prepare_profile_transition core_preflight core_ssh core_system resolve_runtime_ports core_swap core_network core_firewall core_fail2ban optional_docker optional_cf_preferred optional_cloudflaresub module_cloudflare module_certbot_domain module_lucky module_xui module_subscription module_reality module_nginx optional_cf_ws copy_project_persistent; do
  eval "$fn() { printf '%s\\n' $fn >> \\"\\$TD/calls\\"; }"
done
verify_all() { return 0; }
VPSINIT_VERSION=test
REPORT_FILE="$TD/report"
for profile in base-only lucky-web reality-only lucky-reality nginx-reality; do
  cfg="$TD/input.env"
  printf 'PROFILE=%s\\nROOT_DOMAIN=example.com\\n' "$profile" > "$cfg"
  load_config "$cfg"; validate_config
  : > "$TD/calls"
  deploy_apply
  deploy_apply
  [[ "$DEPLOYED_PROFILE" == "$profile" ]]
  [[ ! -f "$PERSIST_DIR/pending.env" ]]
  grep -q STATUS=verified "$STATE_DIR/deployment.env"
  grep -q core_firewall "$TD/calls"
  case "$profile" in
    base-only) ! grep -q module_xui "$TD/calls"; ! grep -q module_lucky "$TD/calls" ;;
    lucky-web) grep -q module_lucky "$TD/calls"; ! grep -q module_xui "$TD/calls" ;;
    *) grep -q module_xui "$TD/calls"; grep -q module_reality "$TD/calls" ;;
  esac
done
''')

    def test_entry_and_installer_help(self):
        for entry in ('vps-init', 'install.sh'):
            p = subprocess.run(['bash', str(ROOT / entry), '--help'], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)

    def test_failed_deployment_retains_candidate_and_verified_config(self):
        self.run_sh('''PROFILE=base-only
cfg="$TD/candidate.env"
printf 'PROFILE=base-only\\nCUSTOM=new\\n' > "$cfg"
printf 'CUSTOM=verified\\n' > "$PERSIST_DIR/config.env"
flock() { :; }
set +e
trap - ERR
(
  set -e
  deployment_begin
  fail_download() { return 28; }
  deployment_step fail_download
  touch "$TD/unsafe"
)
rc=$?
set -e
[[ "$rc" == 28 ]]
[[ ! -f "$TD/unsafe" ]]
cmp "$cfg" "$PERSIST_DIR/pending.env"
grep -qx CUSTOM=verified "$PERSIST_DIR/config.env"
grep -qx STEP=fail_download "$STATE_DIR/deployment.env"
grep -qx EXIT_CODE=28 "$STATE_DIR/deployment.env"
''')

    def test_busy_deploy_does_not_replace_recovery_candidate(self):
        self.run_sh('''PROFILE=base-only
cfg="$TD/new.env"
echo new > "$cfg"
echo running > "$PERSIST_DIR/pending.env"
flock() { return 1; }
set +e
trap - ERR
(set -e; deployment_begin)
rc=$?
set -e
[[ "$rc" != 0 ]]
grep -qx running "$PERSIST_DIR/pending.env"
''')

    def test_port_retry_and_invalid_config(self):
        self.run_sh('''[[ "$(wizard_prompt_port port 22 <<< $'0\\n65536\\n08\\n2222')" == 2222 ]]
set_config_defaults
PROFILE=base-only
SSH_PORT=08
if (validate_config); then exit 99; fi
''')

    def test_wizard_merge_keeps_advanced_configuration(self):
        self.run_sh('''VPSINIT_EXISTING_CONFIG="$TD/old.env"
printf '%s\\n' 'PROFILE=base-only' 'PANEL_DOMAIN_OVERRIDE=custom.example.com' 'REALITY_CANDIDATES=example.com' 'VPSINIT_APT_LOCK_TIMEOUT=90' > "$VPSINIT_EXISTING_CONFIG"
wizard_collect() { :; }
wizard_write_config() { printf 'PROFILE=base-only\\n' > "$1"; }
wizard_collect_config "$TD/candidate.env"
grep -qx PANEL_DOMAIN_OVERRIDE=custom.example.com "$TD/candidate.env"
grep -qx REALITY_CANDIDATES=example.com "$TD/candidate.env"
grep -qx VPSINIT_APT_LOCK_TIMEOUT=90 "$TD/candidate.env"
''')

    def test_edit_validation_failure_preserves_original(self):
        self.run_sh('''source lib/app/menu.sh
printf 'PROFILE=base-only\\n' > "$TD/config.env"
cp "$TD/config.env" "$TD/original"
edit_config_file() { printf 'PROFILE=bad\\n' > "$1"; }
if edit_config_safe "$TD/config.env"; then exit 99; fi
cmp "$TD/config.env" "$TD/original"
''')


if __name__ == '__main__':
    unittest.main()
