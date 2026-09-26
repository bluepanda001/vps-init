#!/usr/bin/env bash
backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR$f"
  log_info "已备份: $f -> $BACKUP_DIR$f"
}
