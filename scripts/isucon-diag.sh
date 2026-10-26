#!/usr/bin/env bash
set -u

APP_UNIT="${1:-isu-go}"
OUT_FILE="$HOME/isucon-diag-$(date '+%Y%m%d-%H%M%S').txt"

{
  printf 'Captured at: '
  date --iso-8601=seconds
  printf 'Host: '
  hostname -f 2>/dev/null || hostname
  printf 'Application unit: %s\n' "$APP_UNIT"

  printf '\n===== uptime =====\n'
  uptime

  printf '\n===== memory =====\n'
  free -h

  printf '\n===== filesystem =====\n'
  df -h /

  printf '\n===== listening sockets =====\n'
  sudo ss -lntp

  printf '\n===== service status =====\n'
  sudo systemctl --no-pager --full status mysql nginx "$APP_UNIT" || true

  printf '\n===== application journal (last 100 lines) =====\n'
  sudo journalctl -u "$APP_UNIT" -n 100 --no-pager || true

  printf '\n===== nginx error log (last 100 lines) =====\n'
  sudo tail -n 100 /var/log/nginx/error.log || true

  printf '\n===== MySQL slow log settings =====\n'
  sudo mysql -Nse "SELECT @@GLOBAL.slow_query_log, @@GLOBAL.long_query_time, @@GLOBAL.log_output, @@GLOBAL.slow_query_log_file;" || true
} 2>&1 | tee "$OUT_FILE"

printf '\nSaved diagnostic output to %s\n' "$OUT_FILE"
