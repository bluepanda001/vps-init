"""Component plans and isolated execution; never operate on the host VPS."""
import os
import pty
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Components(unittest.TestCase):
    def run_sh(self, script, expected=0):
        with tempfile.TemporaryDirectory() as td:
            result = subprocess.run(['bash', '-c', '''set -Eeuo pipefail
source lib/common.sh
source lib/validate.sh
source lib/components.sh
STATE_DIR="$TD/state"; STATE_FILE="$STATE_DIR/state.env"
PERSIST_DIR="$TD/install"; SECRETS_FILE="$TD/secrets"
mkdir -p "$STATE_DIR" "$PERSIST_DIR"
set_config_defaults
''' + script], cwd=ROOT, env=os.environ | {'TD': td}, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            return result.stdout

    def test_profile_add_matrix(self):
        self.run_sh('''for pair in 'base-only reality reality-only' 'base-only lucky lucky-web' \
'reality-only lucky lucky-reality' 'lucky-web reality lucky-reality' \
'nginx-reality lucky lucky-reality' 'reality-only nginx nginx-reality' \
'lucky-reality nginx lucky-reality'; do
 read -r PROFILE component expected <<< "$pair"
 component_plan add "$component"
 [[ "$COMPONENT_TARGET_PROFILE" == "$expected" ]]
done
''')

    def test_docker_plan_all_profiles_is_isolated(self):
        self.run_sh('''for PROFILE in base-only lucky-web reality-only lucky-reality nginx-reality; do
 component_plan add docker
 [[ "$COMPONENT_TARGET_PROFILE" == "$PROFILE" ]]
 [[ "${COMPONENT_STEPS[*]}" == optional_docker ]]
done
''')

    def test_repair_cannot_enable_missing_component(self):
        self.run_sh('PROFILE=base-only\ncomponent_plan repair reality', 1)

    def test_no_silent_gateway_or_ws_dependencies(self):
        self.run_sh('PROFILE=base-only\ncomponent_plan add nginx', 1)
        self.run_sh('PROFILE=reality-only\ncomponent_plan add cf-ws', 1)

    def test_existing_lucky_repair_does_not_reconfigure_reality(self):
        self.run_sh('''PROFILE=lucky-reality
component_plan repair lucky
[[ " ${COMPONENT_STEPS[*]} " != *' module_reality '* ]]
[[ " ${COMPONENT_STEPS[*]} " != *' module_xui '* ]]
''')

    def execution_fixture(self):
        return r'''
source lib/wizard.sh
source lib/app/components.sh
source lib/deployment.sh
DEFAULT_CFG="$PERSIST_DIR/config.env"
printf 'PROFILE=base-only\nCUSTOM_FIELD=keep-me\n' > "$DEFAULT_CFG"
state_set DEPLOYED_PROFILE base-only
state_set REALITY_UUID stable-uuid
state_set SERVER_IP 203.0.113.9
VPSINIT_VERSION=test
COMPONENT_YES=true; COMPONENT_ALLOW_TOPOLOGY=true; COMPONENT_SOURCE=aliyun
component_present() { return 1; }
component_check_ports() { :; }
component_backup() { touch "$COMPONENT_OP/backup-ready"; }
component_verify() { :; }
show_info_summary() { :; }
optional_docker() { echo "$DOCKER_INSTALL_SOURCE" >> "$TD/executed"; }
core_ssh() { exit 99; }
core_system() { exit 99; }
core_firewall() { exit 99; }
'''

    def test_docker_success_preserves_config_and_identity(self):
        self.run_sh(self.execution_fixture() + r'''
component_change add docker
source "$DEFAULT_CFG"
[[ "$CUSTOM_FIELD" == keep-me && "$ENABLE_DOCKER" == true && "$DOCKER_INSTALL_SOURCE" == aliyun ]]
[[ "$REALITY_UUID" == stable-uuid && "$INITIAL_PROFILE" == base-only ]]
[[ ! -d "$STATE_DIR/component-operation" ]]
grep -qx aliyun "$TD/executed"
component_change add docker
[[ $(wc -l < "$TD/executed") -eq 1 ]]
''')

    def test_failure_resume_preserves_candidate_and_only_retries_component(self):
        self.run_sh(self.execution_fixture() + r'''
cp "$DEFAULT_CFG" "$TD/original"
optional_docker() { echo attempt >> "$TD/executed"; exit 23; }
(component_change add docker) &
child=$!; rc=0
wait "$child" || rc=$?
[[ $rc == 23 ]]
cmp "$DEFAULT_CFG" "$TD/original"
[[ -d "$STATE_DIR/component-operation" ]]
grep -q interrupted "$STATE_DIR/component-operation/progress"
optional_docker() { echo "$DOCKER_INSTALL_SOURCE" >> "$TD/executed"; }
component_resume
source "$DEFAULT_CFG"
[[ "$ENABLE_DOCKER" == true ]]
[[ $(wc -l < "$TD/executed") -eq 2 ]]
grep -qx aliyun "$TD/executed"
''')

    def test_external_docker_is_not_adopted(self):
        self.run_sh(self.execution_fixture() + r'''
component_present() { return 0; }
component_change add docker
''', 1)

    def test_pending_full_deployment_blocks_components(self):
        self.run_sh(self.execution_fixture() + r'''
touch "$PERSIST_DIR/pending.env"
component_change add docker
''', 1)

    def test_pending_component_blocks_full_deployment(self):
        self.run_sh(self.execution_fixture() + r'''
mkdir "$STATE_DIR/component-operation"
deployment_begin "$DEFAULT_CFG"
''', 1)

    def test_changed_config_blocks_resume(self):
        self.run_sh(self.execution_fixture() + r'''
optional_docker() { exit 23; }
(component_change add docker) &
child=$!
wait "$child" || true
printf 'CUSTOM_FIELD=changed\n' >> "$DEFAULT_CFG"
component_resume
''', 1)

    def test_cancel_and_eof_leave_no_pending_operation(self):
        self.run_sh(self.execution_fixture() + r'''
COMPONENT_YES=false
# Avoid Docker source prompt so EOF reaches the confirmation.
COMPONENT_SOURCE=official
(component_change add docker </dev/null) &
child=$!; rc=0
wait "$child" || rc=$?
[[ $rc == 10 ]]
[[ ! -d "$STATE_DIR/component-operation" && ! -f "$TD/executed" ]]
[[ -z "$(find "$STATE_DIR" -name '.component-draft.*')" ]]
''')

    def test_topology_requires_explicit_authorization(self):
        self.run_sh(self.execution_fixture() + r'''
COMPONENT_ALLOW_TOPOLOGY=false
component_change add reality
''', 1)

    def test_candidate_preserves_existing_node_and_subscription_address(self):
        self.run_sh(self.execution_fixture() + r'''
printf 'PROFILE=reality-only\nROOT_DOMAIN=example.com\nENABLE_DOCKER=false\n' > "$DEFAULT_CFG"
load_config "$DEFAULT_CFG"
COMPONENT_ID=lucky; COMPONENT_TARGET_PROFILE=lucky-reality
component_prepare_candidate "$TD/candidate.env"
[[ "$PROFILE" == lucky-reality ]]
[[ "$SUBSCRIPTION_EXPOSE_MODE_RESOLVED" == direct-ip-https ]]
[[ "$REALITY_PUBLIC_ADDRESS" == 203.0.113.9 ]]
[[ "$REALITY_UUID" == stable-uuid ]]
''')

    def test_docker_official_source(self):
        self.run_sh(self.execution_fixture() + r'''
COMPONENT_SOURCE=official
component_change add docker
grep -qx official "$TD/executed"
''')

    def test_plan_has_no_persistent_side_effects(self):
        self.run_sh(self.execution_fixture() + r'''
component_command plan lucky
[[ ! -d "$STATE_DIR/component-operation" && ! -f "$TD/executed" ]]
''')


    def test_mihomo_verification_uses_preserved_public_address(self):
        self.run_sh(r'''
source verify/verify.sh
PROFILE=lucky-reality
SERVER_IP=203.0.113.9; ROOT_DOMAIN=example.com
REALITY_PUBLIC_ADDRESS="$SERVER_IP"
SUBSCRIPTION_EXPOSE_MODE=direct-ip-https
resolve_auto_settings
mihomo_body_direct() { printf 'proxies:\n  server: 203.0.113.9\n  port: 443\n'; }
verify_mihomo_public_endpoint
''')

    def test_incremental_topology_execution_matrix(self):
        for old, component, new in [('base-only', 'reality', 'reality-only'),
                                    ('base-only', 'lucky', 'lucky-web'),
                                    ('lucky-web', 'reality', 'lucky-reality'),
                                    ('reality-only', 'lucky', 'lucky-reality'),
                                    ('reality-only', 'nginx', 'nginx-reality'),
                                    ('nginx-reality', 'lucky', 'lucky-reality')]:
            with self.subTest(old=old, component=component):
                self.run_sh(self.execution_fixture() + f'''
printf 'PROFILE={old}\\nROOT_DOMAIN=example.com\\n' > "$DEFAULT_CFG"
state_set DEPLOYED_PROFILE {old}
for step in module_cloudflare module_certbot_domain module_reality module_xui module_subscription module_lucky module_nginx resolve_runtime_ports component_firewall component_release_nginx_backend; do
 eval "$step() {{ echo $step >> \\"\\$TD/executed\\"; }}"
done
component_change add {component}
source "$DEFAULT_CFG"
[[ "$PROFILE" == {new} && "$INITIAL_PROFILE" == {old} ]]
[[ "$REALITY_UUID" == stable-uuid ]]
[[ ! -d "$STATE_DIR/component-operation" ]]
''')

    def test_shared_lock_blocks_component_change(self):
        self.run_sh(self.execution_fixture() + r'''
exec 8>"$STATE_DIR/deploy.lock"
flock -n 8
component_change add docker
''', 1)

    def test_port_conflict_stops_before_service_mutation(self):
        self.run_sh(self.execution_fixture() + r'''
source lib/app/components.sh
PROFILE=base-only
COMPONENT_ID=reality; COMPONENT_FROM_PROFILE=base-only
COMPONENT_TARGET_PROFILE=reality-only
COMPONENT_STEPS=(module_reality)
port_in_use() { [[ "$1" == 443 ]]; }
ss() { echo 'LISTEN users:(("unmanaged",pid=123,fd=1))'; }
component_check_ports
''', 1)

    def test_verification_failure_does_not_commit(self):
        self.run_sh(self.execution_fixture() + r'''
cp "$DEFAULT_CFG" "$TD/original"
component_verify() { return 1; }
(component_change add docker) &
child=$!; rc=0
wait "$child" || rc=$?
[[ $rc == 1 ]]
cmp "$DEFAULT_CFG" "$TD/original"
[[ -d "$STATE_DIR/component-operation" ]]
''')

    def test_successful_commit_crash_can_resume(self):
        self.run_sh(self.execution_fixture() + r'''
original_persist=$(declare -f persist_config)
persist_config() { atomic_config_copy "$1" "$PERSIST_DIR/config.env"; exit 23; }
(component_change add docker) &
child=$!; rc=0
wait "$child" || rc=$?
[[ $rc == 23 ]]
eval "$original_persist"
component_resume
[[ ! -d "$STATE_DIR/component-operation" ]]
''')


    def test_concurrent_config_edit_is_not_overwritten(self):
        self.run_sh(self.execution_fixture() + r'''
optional_docker() { printf 'CUSTOM_FIELD=concurrent\n' >> "$DEFAULT_CFG"; }
(component_change add docker) &
child=$!; rc=0
wait "$child" || rc=$?
[[ $rc == 1 ]]
grep -qx CUSTOM_FIELD=concurrent "$DEFAULT_CFG"
''')

    def test_mixed_port_owners_rejected(self):
        self.run_sh(self.execution_fixture() + r'''
source lib/app/components.sh
PROFILE=reality-only
COMPONENT_ID=lucky; COMPONENT_FROM_PROFILE=reality-only
COMPONENT_TARGET_PROFILE=lucky-reality; COMPONENT_STEPS=(module_reality module_lucky module_nginx)
port_in_use() { [[ "$1" == 443 ]]; }
ss() { printf '%s\n' 'LISTEN 0.0.0.0:443 users:(("xray",pid=123,fd=1))' 'LISTEN [::]:443 users:(("caddy",pid=456,fd=1))'; }
component_check_ports
''', 1)

    def test_resume_can_change_docker_source(self):
        self.run_sh(self.execution_fixture() + r'''
COMPONENT_SOURCE=official
optional_docker() { exit 23; }
(component_change add docker) &
child=$!
wait "$child" || true
optional_docker() { echo "$DOCKER_INSTALL_SOURCE" > "$TD/source"; }
component_command resume --source=aliyun --yes
grep -qx aliyun "$TD/source"
''')


    def test_edit_config_refuses_pending_component_operation(self):
        self.run_sh(self.execution_fixture() + r'''
source lib/app/menu.sh
mkdir "$STATE_DIR/component-operation"
edit_config_file() { exit 99; }
edit_config_safe "$DEFAULT_CFG"
''', 1)

    def test_available_components_follow_dependencies(self):
        self.run_sh(self.execution_fixture() + r'''
[[ "$(component_available add | cut -d '|' -f1 | tr '\n' ' ')" == 'docker reality lucky ' ]]
printf 'PROFILE=lucky-reality\nROOT_DOMAIN=example.com\n' > "$DEFAULT_CFG"
state_set DEPLOYED_PROFILE lucky-reality
[[ "$(component_available add | cut -d '|' -f1 | tr '\n' ' ')" == 'docker cf-ws ' ]]
''')

    def test_sqlite_backup_includes_wal(self):
        self.run_sh(r'''
source lib/app/components.sh
python3 - "$TD" <<'PY2'
import sqlite3, subprocess, sys
from pathlib import Path
root=Path(sys.argv[1])
src=root/'live.db'; dst=root/'snapshot.db'
conn=sqlite3.connect(src)
conn.execute('pragma journal_mode=wal')
conn.execute('create table item(value text)')
conn.execute("insert into item values ('preserved')")
conn.commit()
assert Path(str(src)+'-wal').exists()
subprocess.run(['bash','-c','source lib/app/components.sh; component_backup_sqlite "$1" "$2"','test',str(src),str(dst)],check=True)
with sqlite3.connect(dst) as snap:
    assert snap.execute('select value from item').fetchone()==('preserved',)
assert dst.stat().st_mode & 0o777 == 0o600
conn.close()
PY2
''')

    def test_lucky_proxy_uses_tls_for_preserved_ip_subscription(self):
        self.run_sh(r'''
python3 - <<'PY2'
import importlib.util
spec=importlib.util.spec_from_file_location('lucky','modules/lucky/lucky_api.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
posted=[]
def fake(base,method,path,token='',body=None,query=None):
    if method == 'GET': return {'ruleList':[]}
    if method == 'POST': posted.append(body)
    return {}
m.request=fake
m.configure_rule('test','token','panel.example.com','node.example.com','lucky.example.com',12000,2096,18080,'https://203.0.113.9:2096')
sub=next(p for p in posted[0]['ProxyList'] if p['Remark']=='subscription')
assert sub['Locations']==['https://203.0.113.9:2096']
assert sub['LocationInsecureSkipVerify'] is False
PY2
''')



    def test_component_menu_retries_and_returns_after_child_failure(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            entry=root/'vps-init'
            entry.write_text('#!/usr/bin/env bash\nprintf "CALL:%s:%s:%s\\n" "$1" "${2:-}" "${3:-}"\nexit 23\n')
            entry.chmod(0o700)
            (root/'config.env').write_text('PROFILE=base-only\n')
            (root/'state.env').write_text('DEPLOYED_PROFILE=base-only\n')
            script=r'''
source lib/common.sh
source lib/validate.sh
source lib/wizard.sh
source lib/components.sh
source lib/app/components.sh
ROOT_DIR="$TD"; STATE_DIR="$TD"; STATE_FILE="$TD/state.env"; DEFAULT_CFG="$TD/config.env"
components_menu
'''
            master,slave=pty.openpty()
            try:
                proc=subprocess.Popen(['bash','-c',script],cwd=ROOT,env=os.environ|{'TD':td},stdin=slave,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                os.write(master,b'wrong\n1\n1\n\n0\n')
                out,err=proc.communicate(timeout=10)
                self.assertEqual(proc.returncode,0,(out+err).decode())
                self.assertIn(b'CALL:components:add:docker',out)
                self.assertEqual(out.count(b'CALL:components:status:'),2)
                self.assertIn('输入无效'.encode(),err)
            finally:
                os.close(master); os.close(slave)


    def test_real_cli_help_and_plan_load_new_modules(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)/'repo'
            shutil.copytree(ROOT,root,ignore=shutil.ignore_patterns('.git','__pycache__','*.pyc'))
            state=Path(td)/'state'; state.mkdir()
            persist=Path(td)/'persist'; persist.mkdir()
            (state/'state.env').write_text('DEPLOYED_PROFILE=base-only\n')
            (persist/'config.env').write_text('PROFILE=base-only\n')
            common=root/'lib/common.sh'
            text=common.read_text().replace('STATE_DIR="/var/lib/vps-init"',f'STATE_DIR="{state}"').replace('PERSIST_DIR="/opt/vps-init"',f'PERSIST_DIR="{persist}"')
            text=text.replace('require_root() {','require_root() { :; }; ignored_require_root() {')
            common.write_text(text)
            for args in [('--help',),('components','plan','docker')]:
                result=subprocess.run(['bash',str(root/'vps-init'),*args],capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('components' if args[0]=='--help' else 'optional_docker',result.stdout)
            self.assertFalse((state/'component-operation').exists())


    def test_unrelated_xray_inbound_on_future_port_is_not_reused(self):
        self.run_sh(self.execution_fixture() + r'''
source lib/app/components.sh
PROFILE=reality-only; COMPONENT_OP="$STATE_DIR/component-operation"
COMPONENT_ID=lucky; COMPONENT_FROM_PROFILE=reality-only
COMPONENT_TARGET_PROFILE=lucky-reality; COMPONENT_STEPS=(module_reality module_lucky module_nginx)
port_in_use() { [[ "$1" == 1443 ]]; }
ss() { echo 'LISTEN 127.0.0.1:1443 users:(("xray",pid=123,fd=1))'; }
component_check_ports
''', 1)


    def test_backup_failure_stops_before_any_module(self):
        self.run_sh(self.execution_fixture() + r'''
component_backup() { false; touch "$COMPONENT_OP/backup-ready"; }
(component_change add docker) &
child=$!; rc=0
wait "$child" || rc=$?
[[ $rc == 1 ]]
[[ ! -f "$TD/executed" && ! -f "$STATE_DIR/component-operation/backup-ready" ]]
''')


if __name__ == '__main__':
    unittest.main()
