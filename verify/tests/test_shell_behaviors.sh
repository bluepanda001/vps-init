#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

source lib/common.sh
source core/ssh.sh

# SSH Stage 1 must preserve the pre-existing auth values rather than forcing
# root key-only before the second-session test.
SSH_PORT=22
SSH_STAGE_PERMIT_ROOT=yes
SSH_BASE_PASSWORD_AUTH=yes
SSH_BASE_KBD_AUTH=yes
stage="$(render_ssh_stage_config)"
grep -qx 'PermitRootLogin yes' <<<"$stage"
grep -qx 'PasswordAuthentication yes' <<<"$stage"
grep -qx 'KbdInteractiveAuthentication yes' <<<"$stage"
grep -qx 'PubkeyAuthentication yes' <<<"$stage"

SSH_STAGE_PERMIT_ROOT=prohibit-password
SSH_BASE_PASSWORD_AUTH=no
SSH_BASE_KBD_AUTH=no
stage="$(render_ssh_stage_config)"
grep -qx 'PermitRootLogin prohibit-password' <<<"$stage"
grep -qx 'PasswordAuthentication no' <<<"$stage"
grep -qx 'KbdInteractiveAuthentication no' <<<"$stage"

# Certificate identity checks: same key/current IP passes; changed IP or key fails.
td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 2   -keyout "$td/key1.pem" -out "$td/cert1.pem" -subj /CN=test   -addext 'subjectAltName=IP:203.0.113.10' >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$td/key2.pem" >/dev/null 2>&1
cert_key_match "$td/cert1.pem" "$td/key1.pem"
! cert_key_match "$td/cert1.pem" "$td/key2.pem"
cert_has_ip_san "$td/cert1.pem" "203.0.113.10"
! cert_has_ip_san "$td/cert1.pem" "203.0.113.11"

# A transient or auth failure must never delete/replace the previously saved
# Cloudflare token. Use an overridable path and a fake helper exit status.
source modules/cloudflare/apply.sh
PROFILE=lucky-web
DNS_PROVIDER=cloudflare
ROOT_DOMAIN=example.com
LUCKY_DOMAIN=lucky.example.com
SERVER_IP=203.0.113.10
VPSINIT_CLOUDFLARE_TOKEN_FILE="$td/cloudflare.ini"
export VPSINIT_CLOUDFLARE_TOKEN_FILE
printf 'dns_cloudflare_api_token = OLD_TOKEN\n' > "$VPSINIT_CLOUDFLARE_TOKEN_FILE"
cp "$VPSINIT_CLOUDFLARE_TOKEN_FILE" "$td/original-token"

python3() { return 11; }
if (module_cloudflare >/dev/null 2>&1); then
  echo "FAIL: transient Cloudflare validation unexpectedly succeeded" >&2
  exit 1
fi
cmp -s "$VPSINIT_CLOUDFLARE_TOKEN_FILE" "$td/original-token"

python3() { return 10; }
if (module_cloudflare </dev/null >/dev/null 2>&1); then
  echo "FAIL: invalid Cloudflare token unexpectedly succeeded" >&2
  exit 1
fi
cmp -s "$VPSINIT_CLOUDFLARE_TOKEN_FILE" "$td/original-token"
unset -f python3

# Normal apply must ensure packages but must not perform a full apt upgrade.
source core/system.sh
APT_CALLS="$td/apt-calls"
apt-get() { printf '%s\n' "$*" >> "$APT_CALLS"; }
wait_apt_lock() { :; }
timedatectl() { :; }
systemctl() { :; }
dpkg-reconfigure() { :; }
copy_project_persistent() { :; }
core_system >/dev/null
! grep -Eq '(^| )(-y )?upgrade($| )' "$APT_CALLS"
grep -q '^update$' "$APT_CALLS"
grep -q '^install -y ' "$APT_CALLS"

echo "SHELL_BEHAVIORS_OK"
