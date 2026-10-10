#!/usr/bin/env bash
# Test UFW integration entirely with mocks: NEVER touch the machine's firewall.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source lib/common.sh
source core/firewall.sh

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
BACKUP_DIR="$td/backups"
RULES="$td/rules"
CALLS="$td/calls"
ACTIVE="$td/active"
mkdir -p "$BACKUP_DIR"
: > "$RULES"
: > "$CALLS"
printf 'active\n' > "$ACTIVE"

ufw() {
  printf '%s\n' "$*" >> "$CALLS"
  if [[ "$1" == status ]]; then
    if [[ "${2:-}" == numbered ]]; then
      local i=0 port proto comment
      while IFS='|' read -r port proto comment; do
        [[ -n "$port" ]] || continue
        i=$((i+1))
        printf '[ %s] %s/%s ALLOW IN Anywhere # %s\n' "$i" "$port" "$proto" "$comment"
      done < "$RULES"
      return 0
    fi
    printf 'Status: %s\n' "$(cat "$ACTIVE")"
    local port proto comment
    while IFS='|' read -r port proto comment; do
      [[ -n "$port" ]] || continue
      printf '%s/%s ALLOW Anywhere # %s\n' "$port" "$proto" "$comment"
    done < "$RULES"
    return 0
  fi

  if [[ "$1" == allow ]]; then
    local port="${2%/*}" proto="${2#*/}" comment="${4:-}" existing
    existing="$(awk -F'|' -v p="$port" -v t="$proto" '$1==p && $2==t {print 1;exit}' "$RULES")"
    if [[ "$existing" != 1 ]]; then
      printf '%s|%s|%s\n' "$port" "$proto" "$comment" >> "$RULES"
    fi
    return 0
  fi

  if [[ "$1" == --force && "$2" == delete ]]; then
    awk -v n="$3" 'NR!=n' "$RULES" > "$td/next"
    mv "$td/next" "$RULES"
    return 0
  fi
  if [[ "$1" == --force && "$2" == enable ]]; then
    printf 'active\n' > "$ACTIVE"
    return 0
  fi
  if [[ "$1" == default ]]; then return 0; fi
  echo "FAIL: unsupported mocked ufw invocation: $*" >&2
  return 1
}

check_baseline() {
  for port in 22 80 443; do
    vpsinit_ufw_tcp_allowed "$port" || {
      echo "FAIL: missing IPv4 TCP $port for profile $PROFILE" >&2
      exit 1
    }
  done
}

has_rule() {
  local port="$1" proto="$2"
  awk -F'|' -v p="$port" -v t="$proto" '$1==p && $2==t {found=1} END{exit !found}' "$RULES"
}

# Each profile starts from an active, pre-configured firewall, with:
# - admin-owned TCP/UDP rules to preserve
# - project-managed old baseline rules
# - a stale project-managed TCP subscription rule to clean.
for PROFILE in base-only reality-only nginx-reality lucky-reality lucky-web; do
  cat > "$RULES" <<'EOF_RULES'
22|tcp|vps-init ssh
80|tcp|vps-init ip-acme
443|tcp|vps-init reality
2222|tcp|vps-init subscription
8080|tcp|manual application
5353|udp|manual udp
EOF_RULES
  printf 'active\n' > "$ACTIVE"
  : > "$CALLS"
  SSH_PORT=22
  SUBSCRIPTION_PORT=2096
  ENABLE_SUBSCRIPTION_RESOLVED=false
  SUBSCRIPTION_EXPOSE_MODE_RESOLVED=none
  core_firewall > /dev/null
  check_baseline
  has_rule 8080 tcp || { echo "FAIL: manual TCP removed" >&2; exit 1; }
  has_rule 5353 udp || { echo "FAIL: manual UDP removed" >&2; exit 1; }
  ! has_rule 2222 tcp || { echo "FAIL: stale project TCP left open" >&2; exit 1; }
  ! grep -q 'ufw --force reset' "$CALLS"
  ! grep -q 'ufw default ' "$CALLS"
  ! grep -q 'ufw allow .*/udp' "$CALLS"
  ! grep -q 'ufw --force enable' "$CALLS"
  first_allow="$(grep -n '^allow ' "$CALLS" | head -1 | cut -d: -f1)"
  first_delete="$(grep -n '^--force delete ' "$CALLS" | head -1 | cut -d: -f1)"
  [[ -n "$first_allow" && -n "$first_delete" && "$first_allow" -lt "$first_delete" ]] ||
    { echo "FAIL: project cleanup ran before opening baseline" >&2; exit 1; }

  old_count="$(wc -l < "$RULES")"
  : > "$CALLS"
  core_firewall >/dev/null
  check_baseline
  [[ "$(wc -l < "$RULES")" == "$old_count" ]] || {
    echo "FAIL: idempotent apply added duplicate rules" >&2; exit 1;
  }
done

# A non-standard SSH port is *additional* to the always-open TCP 22.
PROFILE=base-only
SSH_PORT=2345
: > "$RULES"
: > "$CALLS"
core_firewall >/dev/null
check_baseline
has_rule 2345 tcp
! grep -q 'ufw default ' "$CALLS"

# Public IP subscription needs its selected port in addition to the baseline.
PROFILE=reality-only
SSH_PORT=22
SUBSCRIPTION_PORT=2096
ENABLE_SUBSCRIPTION_RESOLVED=true
SUBSCRIPTION_EXPOSE_MODE_RESOLVED=direct-ip-https
: > "$RULES"
core_firewall >/dev/null
check_baseline
has_rule 2096 tcp

# When enabling UFW the first time, safe default policy must be applied
# only AFTER allow rules are installed. Existing policy remains untouched.
PROFILE=base-only
ENABLE_SUBSCRIPTION_RESOLVED=false
printf 'inactive\n' > "$ACTIVE"
: > "$RULES"
: > "$CALLS"
core_firewall >/dev/null
check_baseline
[[ "$(cat "$ACTIVE")" == active ]]
allow_at="$(grep -n '^allow ' "$CALLS" | head -1 | cut -d: -f1)"
default_at="$(grep -n '^default ' "$CALLS" | head -1 | cut -d: -f1)"
enable_at="$(grep -n '^--force enable' "$CALLS" | head -1 | cut -d: -f1)"
[[ "$allow_at" -lt "$default_at" && "$default_at" -lt "$enable_at" ]]

echo FIREWALL_BASELINE_OK
