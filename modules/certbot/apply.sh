#!/usr/bin/env bash
module_certbot_domain() {
  profile_has_domain || return 0
  apt-get install -y certbot python3-certbot-dns-cloudflare
  local certdir="/etc/letsencrypt/live/${ROOT_DOMAIN}"
  local email_args=(--register-unsafely-without-email)
  [[ -n "$LE_EMAIL" ]] && email_args=(--email "$LE_EMAIL")

  # Run certonly on every apply. Certbot reuses a healthy lineage and renews it
  # only when needed, while also repairing a missing/incomplete certificate.
  certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 --agree-tos --non-interactive --keep-until-expiring \
    "${email_args[@]}" --cert-name "$ROOT_DOMAIN" -d "$ROOT_DOMAIN" -d "*.${ROOT_DOMAIN}"

  [[ -s "$certdir/fullchain.pem" && -s "$certdir/privkey.pem" ]] || die "域名证书签发失败。"
  openssl x509 -checkend 604800 -noout -in "$certdir/fullchain.pem" >/dev/null 2>&1 || die "Wildcard 证书剩余有效期不足 7 天，请检查 Certbot/Cloudflare。"
  chmod 600 "$certdir/privkey.pem"
  DOMAIN_CERT_FILE="$certdir/fullchain.pem"; DOMAIN_KEY_FILE="$certdir/privkey.pem"
  state_set DOMAIN_CERT_FILE "$DOMAIN_CERT_FILE"; state_set DOMAIN_KEY_FILE "$DOMAIN_KEY_FILE"
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  log_ok "Wildcard 证书可用：$certdir"
}
