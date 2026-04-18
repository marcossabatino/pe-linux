#!/usr/bin/env bash
# System Health Dashboard — real-time overview of critical system metrics
set -euo pipefail

REFRESH_INTERVAL="${REFRESH_INTERVAL:-5}"
ALERT_CPU="${ALERT_CPU:-85}"
ALERT_MEM="${ALERT_MEM:-90}"
ALERT_DISK="${ALERT_DISK:-85}"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

_bar() {
  local pct=$1 width=30
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local color=$GREEN
  (( pct >= 70 )) && color=$YELLOW
  (( pct >= 85 )) && color=$RED
  printf "${color}["
  printf '%0.s#' $(seq 1 $filled)
  printf '%0.s-' $(seq 1 $empty)
  printf "]${RESET} %3d%%" "$pct"
}

_section() { printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n" "$1"; }

collect_cpu() {
  read -r _ user nice sys idle _ < <(grep '^cpu ' /proc/stat)
  local total=$(( user + nice + sys + idle ))
  local used=$(( user + nice + sys ))
  sleep 0.5
  read -r _ user2 nice2 sys2 idle2 _ < <(grep '^cpu ' /proc/stat)
  local total2=$(( user2 + nice2 + sys2 + idle2 ))
  local used2=$(( user2 + nice2 + sys2 ))
  echo $(( (used2 - used) * 100 / (total2 - total) ))
}

collect_mem() {
  local total free buffers cached
  total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  free=$(grep MemFree  /proc/meminfo | awk '{print $2}')
  buffers=$(grep Buffers /proc/meminfo | awk '{print $2}')
  cached=$(grep '^Cached' /proc/meminfo | awk '{print $2}')
  local used=$(( total - free - buffers - cached ))
  local pct=$(( used * 100 / total ))
  echo "$pct $((used/1024)) $((total/1024))"
}

collect_disk() {
  df -h --output=target,pcent,used,size | grep -v 'tmpfs\|udev\|Use%' | head -10
}

collect_load() {
  read -r l1 l5 l15 _ < /proc/loadavg
  echo "$l1 $l5 $l15"
}

collect_top_procs() {
  ps axo pid,comm,%cpu,%mem --sort=-%cpu | head -6 | tail -5
}

collect_net() {
  local iface rx1 tx1 rx2 tx2
  iface=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  [[ -z "$iface" ]] && { echo "N/A"; return; }
  rx1=$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
  tx1=$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)
  sleep 1
  rx2=$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
  tx2=$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)
  local rxk=$(( (rx2 - rx1) / 1024 ))
  local txk=$(( (tx2 - tx1) / 1024 ))
  echo "$iface RX: ${rxk} KB/s  TX: ${txk} KB/s"
}

render() {
  local cpu mem_info load_info
  cpu=$(collect_cpu)
  mem_info=$(collect_mem)
  load_info=$(collect_load)

  clear
  printf "${BOLD}System Health Dashboard${RESET}  —  %s  (refresh: ${REFRESH_INTERVAL}s | Ctrl+C to exit)\n" "$(date '+%F %T')"

  _section "CPU"
  printf "  Usage:  "; _bar "$cpu"; echo
  [[ $cpu -ge $ALERT_CPU ]] && printf "  ${RED}ALERT: CPU above threshold (%s%%)${RESET}\n" "$ALERT_CPU"

  _section "Memory"
  local mpct mused mtotal
  read -r mpct mused mtotal <<< "$mem_info"
  printf "  Usage:  "; _bar "$mpct"; printf "  (%s / %s MB)\n" "$mused" "$mtotal"
  [[ $mpct -ge $ALERT_MEM ]] && printf "  ${RED}ALERT: Memory above threshold (%s%%)${RESET}\n" "$ALERT_MEM"

  _section "Load Average"
  read -r l1 l5 l15 <<< "$load_info"
  printf "  1m: %s   5m: %s   15m: %s\n" "$l1" "$l5" "$l15"

  _section "Disk Usage"
  printf "  %-20s %6s %8s %8s\n" "Mount" "Used%" "Used" "Size"
  while IFS= read -r line; do
    local mount pct used size
    read -r mount pct used size <<< "$line"
    local pctnum="${pct//%/}"
    printf "  %-20s " "$mount"
    _bar "$pctnum"
    printf "  %8s / %s\n" "$used" "$size"
  done < <(collect_disk)
  [[ $(df / --output=pcent | tail -1 | tr -d ' %') -ge $ALERT_DISK ]] && \
    printf "  ${RED}ALERT: Root disk above threshold (%s%%)${RESET}\n" "$ALERT_DISK"

  _section "Network"
  printf "  %s\n" "$(collect_net)"

  _section "Top Processes (CPU)"
  printf "  %6s %-20s %5s %5s\n" "PID" "COMMAND" "CPU%" "MEM%"
  while IFS= read -r line; do
    printf "  %s\n" "$line"
  done < <(collect_top_procs)

  _section "System"
  printf "  Uptime : %s\n" "$(uptime -p)"
  printf "  Kernel : %s\n" "$(uname -r)"
  printf "  Host   : %s\n" "$(hostname -f 2>/dev/null || hostname)"
}

main() {
  if [[ "${1:-}" == "--once" ]]; then
    render; echo
    exit 0
  fi
  while true; do
    render
    sleep "$REFRESH_INTERVAL"
  done
}

main "$@"
