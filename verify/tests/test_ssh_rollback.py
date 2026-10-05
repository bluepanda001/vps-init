#!/usr/bin/env python3
"""Exercise rollback scripts against real files; replace only host services."""
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest
import time

ROOT = Path(__file__).resolve().parents[2]

@unittest.skipUnless(shutil.which('flock'), 'requires flock (Ubuntu util-linux)')
class RollbackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.td = Path(self.temp.name)
        self.dropin = self.td / 'ssh/00-00-vps-init.conf'
        self.dropin.parent.mkdir()
        self.original = 'Port 22\nPermitRootLogin yes\n'
        self.dropin.write_text(self.original)
        # Keep all configuration IO real but confined to the test directory.
        module = (ROOT / 'core/ssh.sh').read_text().replace(
            '/etc/ssh/sshd_config.d', str(self.dropin.parent))
        (self.td / 'ssh.sh').write_text(module)
        self.env = os.environ | {'TD': str(self.td), 'DROPIN': str(self.dropin)}
        self.preamble = r'''
set -Eeuo pipefail
source "$TD/ssh.sh"
STATE_DIR="$TD/state"
BACKUP_DIR="$TD/backups/$RUN"
SSH_KEY_VERIFIED=false
is_true() { [[ "$1" == true ]]; }
log_warn() { :; }
die() { echo "$*" >&2; exit 1; }
SSH_PORT=2222
ss() { echo 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*'; }
sshd() {
  if [[ "${1:-}" == -T ]]; then
    printf 'pubkeyauthentication yes\npermitrootlogin without-password\npasswordauthentication no\n'
  fi
}
systemctl() { printf '%s\n' "$*" >> "$TD/service-events"; }
export -f sshd systemctl
systemd-run() { printf '%s\n' "${@: -1}" > "$TD/$RUN.script"; }
'''

    def run_shell(self, script, run='one', check=True):
        return subprocess.run(['bash', '-c', self.preamble + script],
                              env=self.env | {'RUN': run}, text=True,
                              capture_output=True, check=check)

    def arm(self, run):
        self.run_shell('arm_ssh_stage_rollback', run)
        return Path((self.td / f'{run}.script').read_text().strip())

    def fire(self, script):
        return self.run_shell('bash ' + shlex.quote(str(script)))

    def stage(self):
        self.dropin.write_text('# Managed by vps-init. Stage 1\nPort 2222\n')

    def test_old_timer_cannot_overwrite_successful_retry(self):
        first = self.arm('one')
        self.stage()
        # Separate shell processes model Ctrl+C followed by another apply.
        self.run_shell('''
arm_ssh_stage_rollback
printf 'Port 2222\nPermitRootLogin prohibit-password\n' > "$DROPIN"
cancel_ssh_stage_rollback
''', 'two')
        final = self.dropin.read_text()
        self.fire(first)  # Include a stale callback already queued by systemd.
        self.assertEqual(self.dropin.read_text(), final)
        self.fire(Path((self.td / 'two.script').read_text().strip()))
        self.assertEqual(self.dropin.read_text(), final)

    def test_retry_rollback_preserves_original_baseline(self):
        first = self.arm('one')
        self.stage()
        second = self.arm('two')
        self.fire(first)
        self.assertIn('Stage 1', self.dropin.read_text())
        self.fire(second)
        self.assertEqual(self.dropin.read_text(), self.original)

    def test_initially_absent_dropin_is_removed_on_timeout(self):
        self.dropin.unlink()
        script = self.arm('one')
        self.stage()
        self.fire(script)
        self.assertFalse(self.dropin.exists())

    def test_old_process_cannot_cancel_newer_rollback(self):
        self.run_shell('''
arm_ssh_stage_rollback
printf '%s\n' "$SSH_ROLLBACK_UNIT" > "$TD/old-unit"
''')
        self.stage()
        script = self.arm('two')
        self.run_shell('''
SSH_ROLLBACK_UNIT="$(cat "$TD/old-unit")"
cancel_ssh_stage_rollback
''', 'one')
        self.fire(script)
        self.assertEqual(self.dropin.read_text(), self.original)

    def test_retry_also_cancels_unguarded_legacy_timer(self):
        self.arm('one')
        self.stage()
        # An upgrade interrupted after publishing ownership can leave both a
        # guarded timer and a v1.3.13 timer that has no generation check.
        self.run_shell(r'''
touch "$TD/legacy-pending"
systemctl() {
  if [[ "$1" == list-units ]]; then
    echo 'vps-init-ssh-rollback-111-222.timer loaded active waiting legacy'
  elif [[ "$1" == stop && "${2:-}" == vps-init-ssh-rollback-111-222.timer ]]; then
    rm -f "$TD/legacy-pending"
  fi
}
arm_ssh_stage_rollback
commit_ssh_final_config
# Model the unguarded legacy callback firing only if not canceled.
if [[ -f "$TD/legacy-pending" ]]; then printf 'Port 22\n' > "$DROPIN"; fi
''', 'two')
        self.assertIn('Port 2222', self.dropin.read_text())
        self.assertIn('PasswordAuthentication no', self.dropin.read_text())

    def test_baseline_capture_keeps_live_dropin_in_place(self):
        result = self.run_shell(r'''
sshd() {
  [[ -f "$DROPIN" ]] || return 1
  printf 'permitrootlogin yes\npasswordauthentication yes\nkbdinteractiveauthentication no\n'
}
capture_ssh_baseline
[[ "$SSH_BASE_PASSWORD_AUTH" == yes ]]
''', check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dropin.read_text(), self.original)

    def test_failed_rearm_keeps_previous_timer_valid(self):
        script = self.arm('one')
        self.stage()
        result = self.run_shell('systemd-run() { return 1; }; arm_ssh_stage_rollback',
                                'two', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.fire(script)
        self.assertEqual(self.dropin.read_text(), self.original)

    def test_killed_rearm_keeps_previous_timer_valid(self):
        script = self.arm('one')
        self.stage()
        result = self.run_shell('systemd-run() { kill -KILL "$BASHPID"; }; arm_ssh_stage_rollback',
                                'two', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.fire(script)
        self.assertEqual(self.dropin.read_text(), self.original)

    def test_failed_final_config_keeps_rollback_available(self):
        result = self.run_shell('''
arm_ssh_stage_rollback
write_ssh_final_config() { printf 'broken\\n' > "$DROPIN"; return 23; }
commit_ssh_final_config
''', check=False)
        self.assertEqual(result.returncode, 23)
        self.fire(Path((self.td / 'one.script').read_text().strip()))
        self.assertEqual(self.dropin.read_text(), self.original)

    def test_completed_timeout_cannot_be_committed_as_verified(self):
        result = self.run_shell('''
arm_ssh_stage_rollback
bash "$(cat "$TD/one.script")"
commit_ssh_final_config
''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.dropin.read_text(), self.original)

    def test_timer_cannot_interrupt_final_config_commit(self):
        # Block the host sshd validation while the real final config writer and
        # transaction lock run. A queued timer must wait, then become a no-op.
        script = self.preamble + r'''
arm_ssh_stage_rollback
sshd() {
  if [[ "$1" == -t ]]; then
    touch "$TD/validating"
    while [[ ! -f "$TD/continue" ]]; do sleep 0.02; done
  elif [[ "$1" == -T ]]; then
    printf 'pubkeyauthentication yes\npermitrootlogin without-password\npasswordauthentication no\n'
  fi
}
commit_ssh_final_config
'''
        commit = subprocess.Popen(['bash', '-c', script], env=self.env | {'RUN': 'one'},
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def cleanup():
            (self.td / 'continue').touch()
            if commit.poll() is None:
                commit.terminate()
            commit.communicate(timeout=5)
        self.addCleanup(cleanup)
        deadline = time.monotonic() + 5
        while not (self.td / 'validating').exists():
            if commit.poll() is not None or time.monotonic() > deadline:
                self.fail('final config did not reach sshd validation')
            time.sleep(0.02)
        callback = Path((self.td / 'one.script').read_text().strip())
        timer = subprocess.Popen(['bash', '-c', self.preamble +
                                  'touch "$TD/timer-started"; bash ' + shlex.quote(str(callback))],
                                 env=self.env | {'RUN': 'timer'},
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: timer.communicate(timeout=5))
        while not (self.td / 'timer-started').exists():
            if timer.poll() is not None or time.monotonic() > deadline:
                self.fail('timer process did not start')
            time.sleep(0.02)
        (self.td / 'continue').touch()
        out, err = commit.communicate(timeout=5)
        self.assertEqual(commit.returncode, 0, out + err)
        out, err = timer.communicate(timeout=5)
        self.assertEqual(timer.returncode, 0, out + err)
        self.assertIn('Port 2222', self.dropin.read_text())
        self.assertIn('PasswordAuthentication no', self.dropin.read_text())
        self.assertFalse((self.td / 'state/ssh-stage-rollback/current').exists())

if __name__ == '__main__':
    unittest.main()
