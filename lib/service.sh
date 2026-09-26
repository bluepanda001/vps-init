#!/usr/bin/env bash
service_enable_start() { systemctl enable --now "$1"; }
service_restart() { systemctl restart "$1"; }
service_active() { systemctl is-active --quiet "$1"; }
