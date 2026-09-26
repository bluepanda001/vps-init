#!/usr/bin/env bash

_vpsinit_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log_info()  { printf '\033[1;34m[%s] [INFO]\033[0m %s\n' "$(_vpsinit_ts)" "$*"; }
log_ok()    { printf '\033[1;32m[%s] [ OK ]\033[0m %s\n' "$(_vpsinit_ts)" "$*"; }
log_warn()  { printf '\033[1;33m[%s] [WARN]\033[0m %s\n' "$(_vpsinit_ts)" "$*" >&2; }
log_error() { printf '\033[1;31m[%s] [ERR ]\033[0m %s\n' "$(_vpsinit_ts)" "$*" >&2; }
die()       { log_error "$*"; exit 1; }
