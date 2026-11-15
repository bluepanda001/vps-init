"""Regression fixtures from the v1.4.0 field report; no live VPS access."""
import importlib.util
import json
import contextlib
import io
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('xui', ROOT / 'modules/3x-ui/xui_api.py')
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)


class ReportRegressions(unittest.TestCase):
    def rows(self):
        return [dict(target=h+':443', host=h, feasible=True, privateTarget=False)
                for h in ['www.cloudflare.com', 'www.amazon.com', 'foo.pages.dev']]

    def test_scan_cli_and_auto_use_same_safe_default(self):
        with patch.object(api, 'get_obj', return_value=self.rows()):
            with patch('sys.argv', ['xui', '--base', 'http://unused', '--token', 'fixture',
                                    'scan', '--candidates', 'example.com']), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(api.main(), 0)
            rows = json.loads(out.getvalue())
            self.assertEqual([x['target'] for x in rows], ['www.amazon.com:443'])
            automatic = api.select_target('', '', 'auto', '', '')[0]
            manual = api.select_target('', '', 'manual', rows[0]['target'], '')[0]
            self.assertEqual(automatic, manual)

    def test_all_risky_or_incomplete_fails_before_selection(self):
        for rows in ([self.rows()[0]], [{'feasible': True}], []):
            with patch.object(api, 'get_obj', return_value=rows):
                with self.assertRaisesRegex(RuntimeError, 'no safe feasible'):
                    api.scan_safe_targets('', '', '')

    def test_upgrade_success_reboot_and_cancellation(self):
        for confirm, reboot in [('true', 'true'), ('true', 'false'), ('false', 'false')]:
            script = f'''set -Eeuo pipefail
source core/system.sh
require_root() {{ :; }}
log_warn() {{ echo "$*"; }}
log_ok() {{ echo "$*"; }}
confirm() {{ {confirm}; }}
system_reboot_required() {{ {reboot}; }}
wait_apt_lock() {{ :; }}
apt_get_with_lock_retry() {{ echo "APT $*"; }}
core_system_upgrade
echo SUCCESS
'''
            result = subprocess.run(['bash', '-c', script], cwd=ROOT, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('SUCCESS', result.stdout)
            self.assertEqual('APT -y upgrade' in result.stdout, confirm == 'true')
            self.assertEqual('系统提示需要重启。' in result.stdout, reboot == 'true')

    def test_managed_service_fixture_not_host_files(self):
        script = '''set -Eeuo pipefail
source lib/app/deploy.sh
PREVIOUS_DEPLOYED_PROFILE=base-only
PROFILE=base-only
managed_service_owned() { [[ "$1" == vps-init-landing ]]; }
systemctl() { echo "$*"; }
prepare_profile_transition
'''
        r = subprocess.run(['bash', '-c', script], cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), 'disable --now vps-init-landing')


if __name__ == '__main__':
    unittest.main()
