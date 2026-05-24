#!/bin/bash
set -eu

PORT="${PORT:-5432}"
DBM="${DB_M:-dbm}"
DBS="${DB_S:-dbs}"
PGUSER="${PGUSER:-postgres}"
DB_PASS="${DB_PASS:-}"
INTERVAL="${CHECK_INTERVAL:-3}"
EXT_IF="${EXT_IF:-eth0}"

sysctl -w net.ipv4.ip_forward=1 >/dev/null

resolve_ip() {
  getent ahosts "$1" | awk '/STREAM/ {print $1; exit}'
}

psql_check() {
  local host_ip="$1"
  PGPASSWORD="$DB_PASS" psql -h "$host_ip" -U "$PGUSER" -p "$PORT" -c '\q' --no-psqlrc --quiet >/dev/null 2>&1
}

set_dnat_to() {
  local target_ip="$1"
  if iptables -t nat -C PREROUTING -i "$EXT_IF" -p tcp --dport "$PORT" -j DNAT --to-destination "${target_ip}:${PORT}" >/dev/null 2>&1; then
    return
  fi
  if iptables -t nat -S PREROUTING | grep -q -- "--dport $PORT .*DNAT"; then
    num=$(iptables -t nat -L PREROUTING --line-numbers -n | awk -v d="$PORT" '$0 ~ "tcp" && $0 ~ ("dpt:"d) {print $1; exit}')
    if [ -n "$num" ]; then
      iptables -t nat -R PREROUTING "$num" -i "$EXT_IF" -p tcp --dport "$PORT" -j DNAT --to-destination "${target_ip}:${PORT}"
      iptables -t nat -R PREROUTING "$num" -i "$EXT_IF" -p udp --dport "$PORT" -j DNAT --to-destination "${target_ip}:${PORT}"
      return
    fi
  fi
  iptables -t nat -A PREROUTING -i "$EXT_IF" -p tcp --dport "$PORT" -j DNAT --to-destination "${target_ip}:${PORT}"
  iptables -t nat -A PREROUTING -i "$EXT_IF" -p udp --dport "$PORT" -j DNAT --to-destination "${target_ip}:${PORT}"
}

allow_forward_to() {
  local target_ip="$1"
  iptables -C FORWARD -d "$target_ip" -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || \
    iptables -A FORWARD -d "$target_ip" -p tcp --dport "$PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
  iptables -C FORWARD -s "$target_ip" -p tcp --sport "$PORT" -j ACCEPT >/dev/null 2>&1 || \
    iptables -A FORWARD -s "$target_ip" -p tcp --sport "$PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -C FORWARD -d "$target_ip" -p udp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || \
    iptables -A FORWARD -d "$target_ip" -p udp --dport "$PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
  iptables -C FORWARD -s "$target_ip" -p udp --sport "$PORT" -j ACCEPT >/dev/null 2>&1 || \
    iptables -A FORWARD -s "$target_ip" -p udp --sport "$PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT
}

ip1=$(resolve_ip "$DBM")
if [ -z "$ip1" ]; then
  echo "Не могу получить ip от $DBM, выключаюсь" >&2
  exit 1
fi
set_dnat_to "$ip1"
allow_forward_to "$ip1"
echo "$(date): $DBM -> $ip1"

current="$DBM"

while true; do
  sleep "$INTERVAL"

  svc_ip=$(resolve_ip "$DBM")
  if [ -n "$svc_ip" ] && psql_check "$svc_ip"; then
    set_dnat_to "$svc_ip"
    allow_forward_to "$svc_ip"
    if [ "$current" != "$DBM" ]; then
      echo "$(date): сменил на -> $DBM ($svc_ip)"
      current="$DBM"
    fi
  else
    alt_ip=$(resolve_ip "$DBS")
    if [ -n "$alt_ip" ] && psql_check "$alt_ip"; then
      set_dnat_to "$alt_ip"
      allow_forward_to "$alt_ip"
      if [ "$current" != "$DBS" ]; then
        echo "$(date): сменил на -> $DBS ($alt_ip). Завершаюсь."
        current="$DBS"
      fi
      exit 0
    else
      echo "$(date): Обе БД не доступны" >&2
    fi
  fi
done
