#!/bin/bash
set -e

INI_DEFAULT="/etc/zk_cliente.ini"
ENV_FILE="/etc/environment"

SCRIPT_PATH="$(readlink -f "$0")"

MODE=""
INI="$INI_DEFAULT"
INTERVAL="60"

STATE_DIR="/var/lib/zkmonitor_alerta_final"
mkdir -p "$STATE_DIR"

MSG_LOG="$STATE_DIR/messages.log"
LAST_CLEAN_FILE="$STATE_DIR/last_clean.ts"

ACTIVE_PING_FILE="$STATE_DIR/active_ping.ts"
ACTIVE_PING_HOURS="${ACTIVE_PING_HOURS:-24}"
ACTIVE_PING_SECS=$((ACTIVE_PING_HOURS * 3600))

CLEAN_HOURS="${CLEAN_HOURS:-24}"
CLEAN_SECS=$((CLEAN_HOURS * 3600))

UNIT_NAME="zkmonitor"
SERVICE_FILE="/etc/systemd/system/${UNIT_NAME}.service"
TIMER_FILE="/etc/systemd/system/${UNIT_NAME}.timer"

has_dialog() { command -v dialog >/dev/null 2>&1; }

ensure_dialog() {
  if ! has_dialog; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y dialog >/dev/null 2>&1 || true
  fi
}

ensure_tools() {
  command -v curl >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1 || true; apt-get install -y curl >/dev/null 2>&1 || true; }
  command -v systemctl >/dev/null 2>&1 || true
}

is_mode() {
  case "$1" in
    config|install|uninstall|run|monitor|status|"") return 0 ;;
    *) return 1 ;;
  esac
}


parse_args() {
  local a1="${1:-}"
  local a2="${2:-}"
  local a3="${3:-}"

  # Caso: ./script.ini run 60
  if [ -n "$a1" ] && [ -f "$a1" ]; then
    INI="$a1"
    MODE="${a2:-run}"
    INTERVAL="${a3:-60}"
    return
  fi

  # Caso: ./script.ini (sem modo)
  if [ -n "$a1" ] && echo "$a1" | grep -qE '\.ini$'; then
    INI="$a1"
    MODE="${a2:-run}"
    INTERVAL="${a3:-60}"
    return
  fi

  # Caso: ./script status | ./script run | ./script install 60
  if is_mode "$a1"; then
    MODE="${a1:-run}"
    INI="$INI_DEFAULT"
    INTERVAL="${a2:-60}"
    return
  fi

  MODE="run"
  INI="$INI_DEFAULT"
  INTERVAL="60"
}

env_set_kv() {
  local key="$1"
  local val="$2"
  [ -z "$key" ] && return 1

  touch "$ENV_FILE"

  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s#^${key}=.*#${key}=\"${val}\"#g" "$ENV_FILE"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

ini_get() {
  local section="$1"
  local key="$2"
  [ -f "$INI" ] || { echo ""; return; }
  awk -F= -v sec="$section" -v k="$key" '
    function trim(x){ sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
    { line=$0; sub(/\r$/, "", line) }
    line ~ "^[ \t]*\\["sec"\\][ \t]*$" { in_section=1; next }
    in_section && line ~ "^[ \t]*\\[" { in_section=0 }
    in_section && line ~ "^[ \t]*"k"[ \t]*=" {
      sub(/^[^=]*=/, "", line)
      print trim(line)
      exit
    }
  ' "$INI"
}

ini_has_section() {
  local section="$1"
  [ -f "$INI" ] || return 1
  grep -qE "^[[:space:]]*\\[${section}\\][[:space:]]*$" "$INI"
}

ini_list_processes() {
  [ -f "$INI" ] || return 0
  awk '/^\s*\[process_/ { sec=$0; gsub(/[\[\]]/, "", sec); print sec }' "$INI"
}

abs_path() { readlink -f "$1" 2>/dev/null || echo "$1"; }

write_ini_defaults_if_missing() {
  local base="$1"
  [ -z "$base" ] && base="/mnt/basesg"

  if [ ! -f "$INI" ]; then
    cat > "$INI" <<EOF
[parame]
path=${base%/}/parame.ini

[disk]
mount=${base%/}
warn_used_pct=90
crit_used_pct=95
warn_free_gb=20
crit_free_gb=10

[cpu]
cpu_pct_max=90
load1_max=6.0
load5_max=4.0
EOF
    return
  fi

  if ! ini_has_section "parame"; then
    cat >> "$INI" <<EOF

[parame]
path=${base%/}/parame.ini
EOF
  fi

  if ! ini_has_section "disk"; then
    cat >> "$INI" <<EOF

[disk]
mount=${base%/}
warn_used_pct=90
crit_used_pct=95
warn_free_gb=20
crit_free_gb=10
EOF
  fi

  if ! ini_has_section "cpu"; then
    cat >> "$INI" <<EOF

[cpu]
cpu_pct_max=90
load1_max=6.0
load5_max=4.0
EOF
  fi
}

append_process_section() {
  local idx="$1"
  local name="$2"
  local exec="$3"
  cat >> "$INI" <<EOF

[process_${idx}]
name=${name}
exec=${exec}
EOF
}

write_processes_from_list() {
  local base="$1"
  shift
  local procs=("$@")

  local idx=1
  for p in "${procs[@]}"; do
    [ -z "$p" ] && continue
    local name
    name="$(basename "$p")"
    name="${name%.l}"
    append_process_section "$idx" "$name" "${base%/}/${p}"
    idx=$((idx+1))
  done
}

config_wizard() {
  ensure_tools
  ensure_dialog

  local token chat base n i
  local procs=()

  if has_dialog && [ -t 0 ]; then
    token="$(dialog --stdout --title "Config Telegram" --inputbox "TG_TOKEN (cole aqui)" 10 70 "")"
    [ -z "$token" ] && exit 0
    chat="$(dialog --stdout --title "Config Telegram" --inputbox "TG_CHAT_ID (1 ou mais, separados por vírgula. Ex: -1001,-1002)" 10 70 "")"
    [ -z "$chat" ] && exit 0
    base="$(dialog --stdout --title "Config Cliente" --inputbox "Caminho da base (ex: /mnt/basesg)" 10 70 "/mnt/basesg")"
    [ -z "$base" ] && exit 0
    n="$(dialog --stdout --title "Processos" --inputbox "Quantos executáveis monitorar?" 10 70 "2")"
    [ -z "$n" ] && exit 0

    i=1
    while [ "$i" -le "$n" ]; do
      local p
      p="$(dialog --stdout --title "Processo $i" --inputbox "Nome do arquivo .l (ex: hmenu.l)" 10 70 "")"
      [ -n "$p" ] && procs+=("$p")
      i=$((i+1))
    done
  else
    [ -t 0 ] || { echo "Sem TTY para configurar. Rode: $SCRIPT_PATH config"; exit 1; }
    read -r -p "TG_TOKEN: " token
    read -r -p "TG_CHAT_ID (1 ou mais separados por vírgula): " chat
    read -r -p "Caminho da base (ex: /mnt/basesg): " base
    read -r -p "Quantos executáveis monitorar? " n
    i=1
    while [ "$i" -le "$n" ]; do
      read -r -p "Arquivo .l #$i (ex: hmenu.l): " p
      [ -n "$p" ] && procs+=("$p")
      i=$((i+1))
    done
  fi

  env_set_kv "TG_TOKEN" "$token"
  env_set_kv "TG_CHAT_ID" "$chat"

  write_ini_defaults_if_missing "$base"

  local existing_proc_count
  existing_proc_count="$(ini_list_processes | wc -l | tr -d ' ')"
  if [ "${existing_proc_count:-0}" -eq 0 ]; then
    write_processes_from_list "$base" "${procs[@]}"
  fi

  . "$ENV_FILE" || true

  if has_dialog && [ -t 0 ]; then
    dialog --msgbox "OK!\n\nCriado/Atualizado:\n- $ENV_FILE\n- $INI\n\nAgora:\n  $SCRIPT_PATH install 60\n" 14 70
  else
    echo "OK! Criado/Atualizado:"
    echo "- $ENV_FILE"
    echo "- $INI"
    echo "Agora: $SCRIPT_PATH install 60"
  fi
}

tg_chat_list() {
  echo "${TG_CHAT_ID:-}" | tr ';' ',' | tr -d '\r' | awk -v RS=',' '
    function trim(x){ sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
    { v=trim($0); if(v!="") print v }
  '
}


need_env_config() {
  [ -f "$ENV_FILE" ] && . "$ENV_FILE" >/dev/null 2>&1 || true
  [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] && return 1
  return 0
}

ensure_env_or_config() {
  if need_env_config; then
    if [ -t 0 ]; then
      config_wizard
      [ -f "$ENV_FILE" ] && . "$ENV_FILE" >/dev/null 2>&1 || true
    else
      echo "TG_TOKEN/TG_CHAT_ID não definidos em $ENV_FILE."
      echo "Rode uma vez com terminal: $SCRIPT_PATH config"
      exit 1
    fi
  fi
}

install_systemd() {
  ensure_tools
  ensure_env_or_config

  if [ -z "$INTERVAL" ] || ! echo "$INTERVAL" | grep -qE '^[0-9]+$'; then
    echo "Intervalo inválido: $INTERVAL"
    exit 1
  fi

  chmod +x "$SCRIPT_PATH" 2>/dev/null || true

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ZK Monitor (Telegram Alerts)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
WorkingDirectory=$(dirname "$SCRIPT_PATH")
ExecStart=$SCRIPT_PATH run
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=ZK Monitor Timer (every ${INTERVAL}s)

[Timer]
OnBootSec=20
OnUnitActiveSec=${INTERVAL}
AccuracySec=1
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 || true

  echo "OK! Timer ativo:"
  systemctl status "${UNIT_NAME}.timer" --no-pager || true
}


uninstall_systemd() {
  systemctl disable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$TIMER_FILE"
  systemctl daemon-reload
  echo "Removido."
}

disk_stats() {
  local mount="$1"
  df -BG -P "$mount" 2>/dev/null | awk 'NR==2{
    gsub(/G/,"",$2); gsub(/G/,"",$3); gsub(/G/,"",$4); gsub(/%/,"",$5);
    print $2" "$3" "$4" "$5
  }'
}

load_avg() { awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || echo ""; }

cpu_percent() {
  local f="$STATE_DIR/cpu.stat"
  local user nice system idle iowait irq softirq steal guest guest_nice
  read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  local idle_now=$((idle + iowait))
  local total_now=$((user + nice + system + idle + iowait + irq + softirq + steal))
  local total_prev=0
  local idle_prev=0
  if [ -f "$f" ]; then
    read -r total_prev idle_prev < "$f" || true
  fi
  echo "$total_now $idle_now" > "$f"
  local dt=$((total_now - total_prev))
  local di=$((idle_now - idle_prev))
  [ "$dt" -le 0 ] && { echo "0"; return; }
  echo $(( (100 * (dt - di)) / dt ))
}

parame_kv() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || { echo ""; return; }
  awk -F= -v k="$key" '
    function trim(x){ sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
    { line=$0; sub(/\r$/, "", line) }
    line ~ "^[ \t]*"k"[ \t]*=" {
      sub(/^[^=]*=/, "", line)
      print trim(line)
      exit
    }
  ' "$file"
}

get_ip_local() { ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'; }

send() {
  local text="$1"
  local chat_id resp ok desc msg_id

  while read -r chat_id; do
    [ -z "$chat_id" ] && continue

    resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d "chat_id=${chat_id}" \
      --data-urlencode "text=${text}")

    ok=$(echo "$resp" | awk -F'"ok":' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    desc=$(echo "$resp" | awk -F'"description":"' '{print $2}' | awk -F'"' '{print $1}')

    msg_id=$(echo "$resp" | awk -F'"message_id":' '{print $2}' | awk -F',' '{print $1}' | tr -dc '0-9')

    if [ "$ok" != "true" ]; then
      echo "$(date '+%F %T') chat=${chat_id} FAIL: ${desc:-sem_descricao} resp=$resp" >> "$STATE_DIR/telegram_errors.log"
      continue
    fi

    [ -n "$msg_id" ] && echo "${chat_id}:${msg_id}" >> "$MSG_LOG"
  done < <(tg_chat_list)
}

clean_telegram() {
  local now last
  now=$(date +%s)
  last=0
  [ -f "$LAST_CLEAN_FILE" ] && last="$(cat "$LAST_CLEAN_FILE" 2>/dev/null || echo 0)"
  [ $((now - last)) -lt "$CLEAN_SECS" ] && return 0
  [ ! -f "$MSG_LOG" ] && { echo "$now" > "$LAST_CLEAN_FILE"; return 0; }

  while read -r line; do
    [ -z "$line" ] && continue
    local chat_id mid
    chat_id="${line%%:*}"
    mid="${line##*:}"
    [ -z "$chat_id" ] && continue
    [ -z "$mid" ] && continue

    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/deleteMessage" \
      -d "chat_id=${chat_id}" \
      -d "message_id=${mid}" >/dev/null || true
  done < "$MSG_LOG"


  > "$MSG_LOG"
  echo "$now" > "$LAST_CLEAN_FILE"
}

send_active_ping() {
  local now last ip_local parame_path nomefantasia codigocliente cnpjbase

  now=$(date +%s)
  last=0
  [ -f "$ACTIVE_PING_FILE" ] && last="$(cat "$ACTIVE_PING_FILE" 2>/dev/null || echo 0)"

  [ $((now - last)) -lt "$ACTIVE_PING_SECS" ] && return 0

  ip_local="$(get_ip_local)"

  parame_path="$(ini_get parame path)"
  parame_path="$(abs_path "$parame_path" 2>/dev/null || echo "$parame_path")"

  nomefantasia="$(parame_kv "$parame_path" nomefantasia)"
  codigocliente="$(parame_kv "$parame_path" codigocliente)"
  cnpjbase="$(parame_kv "$parame_path" cnpjfilialbase)"

  [ -z "$nomefantasia" ] && nomefantasia="(sem nomefantasia)"
  [ -z "$codigocliente" ] && codigocliente="-"
  [ -z "$cnpjbase" ] && cnpjbase="-"

  send "✅ SG Monitor ATIVO
Cliente: ${nomefantasia}
Código: ${codigocliente} | CNPJ base: ${cnpjbase}
Host: $(hostname) | IP: ${ip_local}
Data/Hora: $(date '+%d/%m/%Y %H:%M:%S')" || true

  echo "$now" > "$ACTIVE_PING_FILE"
}

find_pids_for_exec() {
  local exec_raw="$1"
  local exec_base exec_noext out lines

  exec_base="$(basename "$exec_raw")"
  exec_noext="${exec_base%.l}"

  out=""

  lines="$(pgrep -af "[/\.]${exec_base}(\s|$)" 2>/dev/null || true)"
  [ -n "$lines" ] && out="${out}${lines}"$'\n'

  lines="$(pgrep -af "[/\.]${exec_noext}(\s|$)" 2>/dev/null || true)"
  [ -n "$lines" ] && out="${out}${lines}"$'\n'

  lines="$(pgrep -af "${exec_base}" 2>/dev/null || true)"
  [ -n "$lines" ] && out="${out}${lines}"$'\n'

  lines="$(pgrep -af "${exec_noext}" 2>/dev/null || true)"
  [ -n "$lines" ] && out="${out}${lines}"$'\n'

  echo "$out" | awk '{print $1}' | awk 'NF' | sort -u
}

ini_get_raw() {
  local section="$1"
  local key="$2"
  [ -f "$INI" ] || { echo ""; return; }
  awk -F= -v sec="$section" -v k="$key" '
    function trim(x){ sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
    { line=$0; sub(/\r$/, "", line) }
    line ~ "^[ \t]*\\["sec"\\][ \t]*$" { in_section=1; next }
    in_section && line ~ "^[ \t]*\\[" { in_section=0 }
    in_section && line ~ "^[ \t]*"k"[ \t]*=" {
      sub(/^[^=]*=/, "", line)
      print trim(line)
      exit
    }
  ' "$INI"
}

csv_to_json_array() {
  local s="$1"
  echo "$s" | tr ';' ',' | tr -d '\r' | awk -v RS=',' '
    function trim(x){ sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
    {
      v=trim($0)
      if(v!="") a[++n]=v
    }
    END{
      printf "["
      for(i=1;i<=n;i++){
        gsub(/\\/,"\\\\",a[i])
        gsub(/"/,"\\\"",a[i])
        printf "\"%s\"", a[i]
        if(i<n) printf ","
      }
      printf "]"
    }'
}

send_email_generic_to_responsaveis() {
  local subject="$1"
  local body_text="$2"
  local api_url responsaveis token payload

  api_url="$(ini_get_raw email api_url | tr -d '\r' | xargs)"
  responsaveis="$(ini_get_raw email responsaveis | tr -d '\r' | xargs)"
  token="$(ini_get_raw email token | tr -d '\r' | xargs)"

  [ -z "$api_url" ] && return 0
  [ -z "$responsaveis" ] && return 0
  [ -z "$token" ] && return 0

  payload="$(
    jq -n \
      --arg token "$token" \
      --arg subject "$subject" \
      --arg body "$body_text" \
      --arg emails "$responsaveis" \
      '{
        token: $token,
        to_emails: ($emails | gsub(" ";"") | split(",")),
        subject: $subject,
        body_text: $body
      }'
  )"

  curl -sS -X POST "$api_url" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null 2>&1 || true
}

run_once() {
  ensure_env_or_config
  send_active_ping

  local parame_path disk_mount warn_used_pct crit_used_pct warn_free_gb crit_free_gb
  local cpu_pct_max load1_max load5_max

  parame_path="$(ini_get parame path)"
  parame_path="$(abs_path "$parame_path" 2>/dev/null || echo "$parame_path")"

  disk_mount="$(ini_get disk mount)"; [ -z "$disk_mount" ] && disk_mount="/"

  warn_used_pct="$(ini_get disk warn_used_pct)"; [ -z "$warn_used_pct" ] && warn_used_pct="90"
  crit_used_pct="$(ini_get disk crit_used_pct)"; [ -z "$crit_used_pct" ] && crit_used_pct="95"
  warn_free_gb="$(ini_get disk warn_free_gb)"; [ -z "$warn_free_gb" ] && warn_free_gb="20"
  crit_free_gb="$(ini_get disk crit_free_gb)"; [ -z "$crit_free_gb" ] && crit_free_gb="10"

  cpu_pct_max="$(ini_get cpu cpu_pct_max)"; [ -z "$cpu_pct_max" ] && cpu_pct_max="90"
  load1_max="$(ini_get cpu load1_max)"; [ -z "$load1_max" ] && load1_max="6.0"
  load5_max="$(ini_get cpu load5_max)"; [ -z "$load5_max" ] && load5_max="4.0"

  local ip_local
  ip_local="$(get_ip_local)"

  local nomefantasia codigocliente cnpjbase dataversao nomeversao revisao ultatuali
  nomefantasia="$(parame_kv "$parame_path" nomefantasia)"
  codigocliente="$(parame_kv "$parame_path" codigocliente)"
  cnpjbase="$(parame_kv "$parame_path" cnpjfilialbase)"
  dataversao="$(parame_kv "$parame_path" dataversao)"
  nomeversao="$(parame_kv "$parame_path" nomeversao)"
  revisao="$(parame_kv "$parame_path" revisao)"
  ultatuali="$(parame_kv "$parame_path" ultatuali)"

  [ -z "$nomefantasia" ] && nomefantasia="(sem nomefantasia)"
  [ -z "$codigocliente" ] && codigocliente="-"
  [ -z "$cnpjbase" ] && cnpjbase="-"
  [ -z "$dataversao" ] && dataversao="-"
  [ -z "$nomeversao" ] && nomeversao="-"
  [ -z "$revisao" ] && revisao="-"
  [ -z "$ultatuali" ] && ultatuali="-"

  local stats total_gb used_gb free_gb used_pct disk_level disk_block
  stats="$(disk_stats "$disk_mount" || true)"
  total_gb="$(echo "$stats" | awk '{print $1}')"
  used_gb="$(echo "$stats" | awk '{print $2}')"
  free_gb="$(echo "$stats" | awk '{print $3}')"
  used_pct="$(echo "$stats" | awk '{print $4}')"

  disk_level="ERRO"
  disk_block="Disco (${disk_mount}): erro ao ler"
  if [ -n "$total_gb" ] && [ -n "$used_pct" ] && [ -n "$free_gb" ]; then
    disk_level="OK"
    if [ "$used_pct" -ge "$crit_used_pct" ] || [ "$free_gb" -le "$crit_free_gb" ]; then
      disk_level="CRITICO"
    elif [ "$used_pct" -ge "$warn_used_pct" ] || [ "$free_gb" -le "$warn_free_gb" ]; then
      disk_level="ATENCAO"
    fi
    disk_block="Disco (${disk_mount}): Total ${total_gb}GB | Usado ${used_gb}GB (${used_pct}%) | Livre ${free_gb}GB | Nível ${disk_level}"
  fi

  local la l1 l5 l15 cpu_pct cpu_alert
  la="$(load_avg)"
  l1="$(echo "$la" | awk '{print $1}')"
  l5="$(echo "$la" | awk '{print $2}')"
  l15="$(echo "$la" | awk '{print $3}')"
  cpu_pct="$(cpu_percent)"

  cpu_alert=0
  awk -v a="$l1" -v b="$load1_max" 'BEGIN{exit !(a>b)}' 2>/dev/null && cpu_alert=1
  awk -v a="$l5" -v b="$load5_max" 'BEGIN{exit !(a>b)}' 2>/dev/null && cpu_alert=1
  [ "$cpu_pct" -ge "$cpu_pct_max" ] && cpu_alert=1

  local alerts=""
  if [ "$disk_level" != "OK" ]; then
    alerts="${alerts}• DISCO ${disk_level}: ${used_gb:-"-"}GB/${total_gb:-"-"}GB (${used_pct:-"-"}%) | livre ${free_gb:-"-"}GB\n"
  fi
  if [ "$cpu_alert" -eq 1 ]; then
    alerts="${alerts}• CPU/LOAD: cpu ${cpu_pct}% | load ${l1} ${l5} ${l15}\n"
  fi

  local proc_down="" proc_down_count=0
  while read -r sec; do
    [ -z "$sec" ] && continue

    local name exec_raw pids_count
    name="$(ini_get "$sec" name)"
    exec_raw="$(ini_get "$sec" exec)"
    [ -z "$name" ] && name="$sec"
    [ -z "$exec_raw" ] && continue

    pids_count="$(find_pids_for_exec "$exec_raw" | wc -l | tr -d ' ')"
    if [ "${pids_count:-0}" -le 0 ]; then
      proc_down_count=$((proc_down_count+1))
      proc_down="${proc_down}• ${name}: FECHADO | ${exec_raw}\n"
    fi
  done < <(ini_list_processes)

  if [ "$proc_down_count" -gt 0 ]; then
    alerts="${alerts}• PROCESSOS FECHADOS: ${proc_down_count}\n"
  fi

  if [ "$proc_down_count" -gt 0 ]; then
    local subject body
    subject="ALERTA: Processos fechados - ${nomefantasia}"
    body="Cliente: ${nomefantasia}
Código: ${codigocliente} | CNPJ base: ${cnpjbase}
Host: $(hostname) | IP: ${ip_local}
Data/Hora: $(date '+%d/%m/%Y %H:%M:%S')

Processos fechados (${proc_down_count}):
$(printf "%b" "$proc_down")"

    send_email_generic_to_responsaveis "$subject" "$body"
  fi

  if [ -n "$alerts" ]; then
    send "🚨 ALERTA - ${nomefantasia}
Cliente: ${codigocliente} | CNPJ base: ${cnpjbase}
Host: $(hostname) | IP: ${ip_local}
Versão: ${nomeversao} | Data: ${dataversao} | Revisão: ${revisao} | Atual: ${ultatuali}

${disk_block}
CPU: ${cpu_pct}% | Load: ${l1} ${l5} ${l15}

$(printf "%b" "$alerts")$( [ "$proc_down_count" -gt 0 ] && printf "\nProcessos:\n%b" "$proc_down" || true )"
  fi

  clean_telegram
}

usage() {
  echo "Uso:"
  echo "  $SCRIPT_PATH config"
  echo "  $SCRIPT_PATH run"
  echo "  $SCRIPT_PATH install 60"
  echo "  $SCRIPT_PATH uninstall"
  echo ""
  echo "Compatível também com:"
  echo "  $SCRIPT_PATH /etc/zk_cliente.ini config"
  echo "  $SCRIPT_PATH /etc/zk_cliente.ini install 60"
}

status_processes() {
  ensure_env_or_config

  local parame_path nomefantasia codigocliente cnpjbase ip_local
  ip_local="$(get_ip_local)"

  parame_path="$(ini_get parame path)"
  parame_path="$(abs_path "$parame_path" 2>/dev/null || echo "$parame_path")"

  nomefantasia="$(parame_kv "$parame_path" nomefantasia)"
  codigocliente="$(parame_kv "$parame_path" codigocliente)"
  cnpjbase="$(parame_kv "$parame_path" cnpjfilialbase)"

  [ -z "$nomefantasia" ] && nomefantasia="(sem nomefantasia)"
  [ -z "$codigocliente" ] && codigocliente="-"
  [ -z "$cnpjbase" ] && cnpjbase="-"

  local ativos="" inativos="" total=0 a=0 d=0
  while read -r sec; do
    [ -z "$sec" ] && continue

    local name exec_raw pids
    name="$(ini_get "$sec" name)"
    exec_raw="$(ini_get "$sec" exec)"
    [ -z "$name" ] && name="$sec"
    [ -z "$exec_raw" ] && continue

    pids="$(find_pids_for_exec "$exec_raw")"

    total=$((total+1))
    if [ -n "$pids" ]; then
      a=$((a+1))
      ativos="${ativos}• ${name}: ATIVO | pids: $(echo "$pids" | tr '\n' ' ' | xargs)\n"
    else
      d=$((d+1))
      inativos="${inativos}• ${name}: INATIVO | ${exec_raw}\n"
    fi
  done < <(ini_list_processes)

  local msg="📌 STATUS PROCESSOS - ${nomefantasia}
Cliente: ${codigocliente} | CNPJ base: ${cnpjbase}
Host: $(hostname) | IP: ${ip_local}
Data/Hora: $(date '+%d/%m/%Y %H:%M:%S')

Ativos: ${a}/${total}
$(printf "%b" "$ativos")

Inativos: ${d}/${total}
$(printf "%b" "$inativos")"

  if [ -t 1 ]; then
    printf "%b\n" "$msg"
  fi

  send "$msg" || true
}
parse_args "${1:-}" "${2:-}" "${3:-}"

case "$MODE" in
  config)    config_wizard ;;
  install)   install_systemd ;;
  uninstall) uninstall_systemd ;;
  status)    status_processes ;;
  run|monitor|"") run_once ;;
  *) usage; exit 1 ;;
esac

