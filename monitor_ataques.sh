#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/environment"
AUTH_LOG="${AUTH_LOG:-/var/log/auth.log}"
JAIL="${JAIL:-sshd}"

TOP_N="${TOP_N:-15}"
WINDOW_SECS="${WINDOW_SECS:-300}"

STATE_DIR="/var/lib/zksecmon"
mkdir -p "$STATE_DIR"

UNIT_RUN="zksecmon-run"
UNIT_SUMMARY="zksecmon-summary"

SERVICES=("zkbi-api.service" "zkbi-server.service")

load_env() {
  set +u
  [ -f "$ENV_FILE" ] && . "$ENV_FILE" >/dev/null 2>&1 || true
  set -u
}

need_vars() {
  [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || { echo "ERRO: defina TG_TOKEN e TG_CHAT_ID em $ENV_FILE"; exit 1; }
}

tg_send() {
  local text="$1"
  local max=3500
  local i=0
  local part resp
  while [ $i -lt ${#text} ]; do
    part="${text:$i:$max}"
    resp="$(curl -sS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=${part}" \
      -d "disable_web_page_preview=true")"
    echo "$resp" | grep -q '"ok":true' || { echo "TELEGRAM_RESPONSE=$resp"; return 1; }
    i=$((i + max))
    sleep 0.2
  done
}

fail2ban_banned() {
  command -v fail2ban-client >/dev/null 2>&1 || { echo ""; return; }
  fail2ban-client status "$JAIL" 2>/dev/null | awk '/Banned IP list:/ {sub(/^.*Banned IP list:[[:space:]]*/, "", $0); print $0}'
}

service_status_block() {
  command -v systemctl >/dev/null 2>&1 || { echo "• zkbi-api.service: unknown"; echo "• zkbi-server.service: unknown"; return; }
  local out="" s st
  for s in "${SERVICES[@]}"; do
    st="$(systemctl is-active "$s" 2>/dev/null || echo "unknown")"
    out="${out}• ${s}: ${st}\n"
  done
  printf "%b" "$out"
}

active_ssh() {
  who 2>/dev/null || true
}

top_attackers() {
  awk '
  /Failed password/||/Invalid user/||/authentication failure/||/Did not receive identification/||/Connection closed by authenticating user/{
    ip="";
    for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip=$i;
    if(ip!="") c[ip]++
  }
  END{for(k in c) printf "%d %s\n", c[k], k}
  ' "$AUTH_LOG" 2>/dev/null | sort -nr | head -n "$TOP_N"
}

last_event_line() {
  grep -E "Failed password|Invalid user|authentication failure|Did not receive identification|Connection closed by authenticating user" "$AUTH_LOG" 2>/dev/null | tail -n 1 || true
}

attacks_last_window() {
  local cutoff year
  cutoff="$(( $(date +%s) - WINDOW_SECS ))"
  year="$(date +%Y)"
  awk -v cutoff="$cutoff" -v year="$year" '
  BEGIN{
    mon["Jan"]=1;mon["Feb"]=2;mon["Mar"]=3;mon["Apr"]=4;mon["May"]=5;mon["Jun"]=6;
    mon["Jul"]=7;mon["Aug"]=8;mon["Sep"]=9;mon["Oct"]=10;mon["Nov"]=11;mon["Dec"]=12;
  }
  /Failed password/||/Invalid user/||/authentication failure/||/Did not receive identification/||/Connection closed by authenticating user/{
    m=$1; d=$2; t=$3;
    split(t,a,":"); hh=a[1]; mm=a[2]; ss=a[3];
    mo=mon[m]; if(mo=="") next;
    ts=mktime(year" "mo" "d" "hh" "mm" "ss");
    if(ts < cutoff) next;

    ip="";
    for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip=$i;
    if(ip!="") c[ip]++
  }
  END{for(k in c) printf "%d %s\n", c[k], k}
  ' "$AUTH_LOG" 2>/dev/null | sort -nr | head -n 20
}

run_message() {
  local host now ips svc banned who_out
  host="$(hostname -f 2>/dev/null || hostname)"
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  ips="$(attacks_last_window || true)"
  svc="$(service_status_block || true)"
  banned="$(fail2ban_banned | tr -d '\r')"
  who_out="$(active_ssh)"

  [ -n "$ips" ] || return 1

  printf "🛡️ SSH ATAQUES (últimos %ss)\nHost: %s\nData: %s\n\n" "$WINDOW_SECS" "$host" "$now"
  printf "⚙️ Serviços ZKBI:\n%b\n\n" "$svc"
  if [ -n "$banned" ]; then
    printf "⛔ Fail2ban banidos:\n%s\n\n" "$banned"
  else
    printf "⛔ Fail2ban banidos:\n(nenhum)\n\n"
  fi
  if [ -n "$who_out" ]; then
    printf "👤 Conectados (who):\n%s\n\n" "$who_out"
  else
    printf "👤 Conectados (who):\n(ninguém)\n\n"
  fi
  printf "🔥 IPs recentes:\n"
  printf "%s\n" "$ips" | awk '{printf "• %s (%sx)\n",$2,$1}'
}

summary_message() {
  local host now banned who_out svc top last
  host="$(hostname -f 2>/dev/null || hostname)"
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  banned="$(fail2ban_banned | tr -d '\r')"
  who_out="$(active_ssh)"
  svc="$(service_status_block || true)"
  top="$(top_attackers || true)"
  last="$(last_event_line || true)"

  printf "🧾 SUMMARY SSH (%s)\nData: %s\nJail: %s\n\n" "$host" "$now" "$JAIL"
  printf "⚙️ Serviços ZKBI:\n%b\n\n" "$svc"
  if [ -n "$banned" ]; then
    printf "⛔ Fail2ban banidos:\n%s\n\n" "$banned"
  else
    printf "⛔ Fail2ban banidos:\n(nenhum)\n\n"
  fi
  if [ -n "$who_out" ]; then
    printf "👤 Conectados (who):\n%s\n\n" "$who_out"
  else
    printf "👤 Conectados (who):\n(ninguém)\n\n"
  fi
  if [ -n "$top" ]; then
    printf "🔥 Top IPs (histórico):\n%s\n\n" "$top"
  else
    printf "🔥 Top IPs (histórico):\n(sem dados)\n\n"
  fi
  if [ -n "$last" ]; then
    printf "🧾 Última tentativa:\n%s\n" "$last"
  else
    printf "🧾 Última tentativa:\n(sem eventos)\n"
  fi
}

install_units() {
  command -v systemctl >/dev/null 2>&1 || { echo "systemctl não encontrado"; exit 1; }

  local sp
  sp="$(readlink -f "$0")"

  cat > "/etc/systemd/system/${UNIT_RUN}.service" <<EOF
[Unit]
Description=ZK Security Monitor (run)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=$sp run
EOF

  cat > "/etc/systemd/system/${UNIT_RUN}.timer" <<EOF
[Unit]
Description=ZK Security Monitor Timer (run)

[Timer]
OnBootSec=20
OnUnitActiveSec=60
AccuracySec=1
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat > "/etc/systemd/system/${UNIT_SUMMARY}.service" <<EOF
[Unit]
Description=ZK Security Monitor (summary)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=$sp summary
EOF

  cat > "/etc/systemd/system/${UNIT_SUMMARY}.timer" <<EOF
[Unit]
Description=ZK Security Monitor Timer (summary)

[Timer]
OnBootSec=60
OnUnitActiveSec=3600
AccuracySec=1
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${UNIT_RUN}.timer" "${UNIT_SUMMARY}.timer" >/dev/null 2>&1 || true
  systemctl status "${UNIT_RUN}.timer" --no-pager || true
  systemctl status "${UNIT_SUMMARY}.timer" --no-pager || true
}

uninstall_units() {
  command -v systemctl >/dev/null 2>&1 || true
  systemctl disable --now "${UNIT_RUN}.timer" "${UNIT_SUMMARY}.timer" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${UNIT_RUN}.service" "/etc/systemd/system/${UNIT_RUN}.timer"
  rm -f "/etc/systemd/system/${UNIT_SUMMARY}.service" "/etc/systemd/system/${UNIT_SUMMARY}.timer"
  systemctl daemon-reload >/dev/null 2>&1 || true
  echo "Removido."
}

status_info() {
  echo "AUTH_LOG=$AUTH_LOG"
  echo "JAIL=$JAIL"
  echo "WINDOW_SECS=$WINDOW_SECS"
  echo "SERVICES=${SERVICES[*]}"
  command -v systemctl >/dev/null 2>&1 && {
    systemctl status "${UNIT_RUN}.timer" --no-pager >/dev/null 2>&1 && echo "Timer run: ativo" || echo "Timer run: não instalado"
    systemctl status "${UNIT_SUMMARY}.timer" --no-pager >/dev/null 2>&1 && echo "Timer summary: ativo" || echo "Timer summary: não instalado"
  }
}

usage() {
  echo "Uso:"
  echo "  $0 run        (manda só se teve ataque nos últimos 5 min)"
  echo "  $0 summary    (manda o resumo completo)"
  echo "  $0 install    (cria 2 services+timers)"
  echo "  $0 uninstall"
  echo "  $0 status"
}

MODE="${1:-}"
case "$MODE" in
  run)
    load_env
    need_vars
    m="$(run_message || true)"
    [ -n "${m:-}" ] && tg_send "$m"
    ;;
  summary)
    load_env
    need_vars
    tg_send "$(summary_message)"
    ;;
  install)
    install_units
    ;;
  uninstall)
    uninstall_units
    ;;
  status)
    status_info
    ;;
  *)
    usage
    exit 1
    ;;
esac
