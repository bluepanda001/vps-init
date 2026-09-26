#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=/opt/vps-init
# shellcheck source=/dev/null
source /var/lib/vps-init/state.env
python3 "$ROOT_DIR/modules/lucky/lucky_api.py" --user "$LUCKY_USERNAME" --password "$LUCKY_PASSWORD" sync-cert --cert "$DOMAIN_CERT_FILE" --key "$DOMAIN_KEY_FILE"
systemctl restart lucky
