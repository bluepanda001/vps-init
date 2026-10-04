#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=/opt/vps-init
# shellcheck source=/dev/null
source /var/lib/vps-init/state.env
base="http://127.0.0.1:16601"
safe="${LUCKY_SAFE_URL:-}"
safe="${safe#/}"
if [[ -n "$safe" ]] && curl -fsS --max-time 2 -o /dev/null "${base}/${safe}/version"; then
  base="${base}/${safe}"
fi
python3 "$ROOT_DIR/modules/lucky/lucky_api.py" --base "$base" --user "$LUCKY_USERNAME" --password "$LUCKY_PASSWORD" sync-cert --cert "$DOMAIN_CERT_FILE" --key "$DOMAIN_KEY_FILE"
systemctl restart lucky
