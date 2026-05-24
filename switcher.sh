#!/bin/bash
set -euo

PORT="${PORT:-5432}"
PRIMARY_LOCAL_PORT="${PRIMARY_LOCAL_PORT:-5433}"
SECONDARY_LOCAL_PORT="${SECONDARY_LOCAL_PORT:-5434}"
PGUSER="${PGUSER:-postgres}"
DB_PASS="${DB_PASS:-}"
INTERVAL="${CHECK_INTERVAL:-3}"

iptables_bin="${IPTABLES_BIN:-iptables}"
psql_bin="${PSQL_BIN:-psql}"

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

psql_check() {
  local host="$1"
  local port="$2"

  PGPASSWORD="$DB_PASS" "$psql_bin" \
    -h "$host" \
    -U "$PGUSER" \
    -p "$port" \
    -d postgres \
    -c 'SELECT 1' \
    --no-psqlrc \
    --quiet \
    >/dev/null 2>&1
}

remove_redirect_rules() {
  local target_port="$1"

  "$iptables_bin" -t nat -D PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-ports "$target_port" 2>/dev/null || true
  "$iptables_bin" -t nat -D OUTPUT -p tcp --dport "$PORT" -j REDIRECT --to-ports "$target_port" 2>/dev/null || true
}

set_redirect_to() {
  local target_port="$1"

  remove_redirect_rules "$PRIMARY_LOCAL_PORT"
  remove_redirect_rules "$SECONDARY_LOCAL_PORT"

  "$iptables_bin" -t nat -A PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-ports "$target_port"
  "$iptables_bin" -t nat -A OUTPUT -p tcp --dport "$PORT" -j REDIRECT --to-ports "$target_port"
}

current=""

set_redirect_to "$PRIMARY_LOCAL_PORT"
echo "$(date): настроил на -> 127.0.0.1:${PRIMARY_LOCAL_PORT}"
current="primary"

while true; do
  sleep "$INTERVAL"

  if psql_check 127.0.0.1 "$PRIMARY_LOCAL_PORT"; then
    if [ "$current" != "primary" ]; then
      set_redirect_to "$PRIMARY_LOCAL_PORT"
      echo "$(date): сменил на -> 127.0.0.1:${PRIMARY_LOCAL_PORT}"
      current="primary"
    fi
  else
    if psql_check 127.0.0.1 "$SECONDARY_LOCAL_PORT"; then
      if [ "$current" != "secondary" ]; then
        set_redirect_to "$SECONDARY_LOCAL_PORT"
        echo "$(date): сменил на -> 127.0.0.1:${SECONDARY_LOCAL_PORT}. Завершил работу"
        current="secondary"
        exit 0
      fi
    else
      echo "$(date): Обе БД не доступны" >&2
    fi
  fi
done