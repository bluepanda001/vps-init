"""Run bootstrap against local archives with every host path redirected."""
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Bootstrap(unittest.TestCase):
    def exercise(self, broken=False, fail_move=False):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            install = td / 'installed'
            install.mkdir()
            (install / 'config.env').write_text('CUSTOM=keep\n')
            (install / 'pending.env').write_text('CUSTOM=recover\n')
            (install / 'old').write_text('old program')
            archive = td / 'fixture.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                for p in ROOT.rglob('*'):
                    if p.is_file() and '.git' not in p.parts and '__pycache__' not in p.parts:
                        if broken and p.relative_to(ROOT).as_posix() == 'lib/config.sh':
                            continue
                        tar.add(p, arcname='source/' + p.relative_to(ROOT).as_posix())
            script = (ROOT / 'install.sh').read_text()
            # The product entry requires root; tests redirect all paths and
            # deliberately remove that guard, never elevating privileges.
            script = script.replace('[[ ${EUID:-$(id -u)} -eq 0 ]]', 'true')
            script = script.replace('/opt/vps-init', str(install))
            script = script.replace('/usr/local/bin/vps-init', str(td / 'entry'))
            script = script.replace('/var/backups/vps-init-bootstrap', str(td / 'backups'))
            fixture = '''
curl() {
  local out="" arg
  while (( $# )); do
    arg="$1"; shift
    if [[ "$arg" == -o ]]; then out="$1"; shift; fi
  done
  if [[ "$out" == /dev/null ]]; then
    printf '404\\nhttps://github.com/test/repo/releases/latest\\n'
  else
    cp "$ARCHIVE" "$out"
  fi
}
mv() {
  if [[ "${FAIL_MOVE:-0}" == 1 && "$1" == *.new.* ]]; then return 1; fi
  command mv "$@"
}
'''
            script = script.replace('tmp="$(mktemp -d)"', fixture + '\ntmp="$(mktemp -d)"')
            candidate = td / 'installer.sh'
            candidate.write_text(script)
            result = subprocess.run(['bash', str(candidate), '--update', '--no-menu'],
                                    env=os.environ | {'ARCHIVE': str(archive), 'FAIL_MOVE': str(int(fail_move))},
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 1 if broken or fail_move else 0,
                             result.stdout + result.stderr)
            self.assertEqual((install / 'config.env').read_text(), 'CUSTOM=keep\n')
            self.assertEqual((install / 'pending.env').read_text(), 'CUSTOM=recover\n')
            if broken or fail_move:
                self.assertEqual((install / 'old').read_text(), 'old program')
            else:
                self.assertTrue((install / 'lib/app/deploy.sh').exists())
                self.assertTrue((install / 'lib/components.sh').exists())
                self.assertTrue((install / 'lib/app/components.sh').exists())
                self.assertTrue((td / 'entry').is_symlink())

    def test_upgrade_preserves_config_and_pending(self):
        self.exercise()

    def test_incomplete_archive_keeps_old_install(self):
        self.exercise(broken=True)

    def test_failed_switch_restores_old_install(self):
        self.exercise(fail_move=True)


if __name__ == '__main__':
    unittest.main()
