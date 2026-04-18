#!/usr/bin/env bash
# Log Anomaly Detector — detects error spikes, latency outliers, and suspicious patterns
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

DEFAULT_LOG="/var/log/syslog"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-10}"     # errors per minute
LATENCY_THRESHOLD="${LATENCY_THRESHOLD:-500}" # ms
WINDOW_SECONDS="${WINDOW_SECONDS:-300}"       # 5-minute analysis window

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] <logfile>

Options:
  -t, --type     Log type: auto|nginx|apache|syslog|app (default: auto)
  -w, --window   Analysis window in seconds (default: ${WINDOW_SECONDS})
  -e, --errors   Error threshold per minute (default: ${ERROR_THRESHOLD})
  -l, --latency  Latency threshold in ms (default: ${LATENCY_THRESHOLD})
  -f, --follow   Follow log in real time
  -o, --output   Output report to file (markdown)
  -h, --help     Show this help

Examples:
  $0 /var/log/nginx/access.log --type nginx
  $0 /var/log/app.log --follow --errors 5
  $0 /var/log/nginx/access.log -o report.md
EOF
  exit 0
}

detect_type() {
  local file="$1"
  local sample
  sample=$(head -20 "$file" 2>/dev/null || echo "")
  if echo "$sample" | grep -qP '^\S+ \S+ \S+ \['; then echo "nginx"
  elif echo "$sample" | grep -qP '^\[\w+\s+\w+\s+\d+'; then echo "apache"
  elif echo "$sample" | grep -qP '^\w+\s+\d+\s+\d+:\d+:\d+'; then echo "syslog"
  else echo "app"
  fi
}

extract_errors() {
  local file="$1" type="$2"
  case "$type" in
    nginx|apache) grep -iE '"[45][0-9]{2}"' "$file" 2>/dev/null | tail -1000 ;;
    syslog)       grep -iE '\b(error|crit|alert|emerg)\b' "$file" 2>/dev/null | tail -1000 ;;
    *)            grep -iE '\b(error|exception|fatal|critical|panic)\b' "$file" 2>/dev/null | tail -1000 ;;
  esac
}

count_errors_per_minute() {
  local file="$1" type="$2"
  extract_errors "$file" "$type" | \
    grep -oP '\d{2}:\d{2}' | \
    sort | uniq -c | sort -rn | head -20
}

extract_latency() {
  local file="$1"
  grep -oP '"[0-9]+\.[0-9]+"$' "$file" 2>/dev/null | tr -d '"' | \
    awk '{sum+=$1; n++; if($1>max)max=$1} END {
      if(n>0) printf "avg=%.0fms max=%.0fms count=%d\n", sum/n*1000, max*1000, n
    }'
}

extract_top_ips() {
  local file="$1"
  awk '{print $1}' "$file" 2>/dev/null | sort | uniq -c | sort -rn | head -10
}

extract_status_codes() {
  local file="$1"
  grep -oP '"[1-5][0-9]{2}"' "$file" 2>/dev/null | sort | uniq -c | sort -rn | head -15
}

detect_ip_flood() {
  local file="$1"
  awk '{print $1}' "$file" 2>/dev/null | sort | uniq -c | sort -rn | \
    awk -v threshold=100 '$1 > threshold {printf "  %s requests from %s\n", $1, $2}'
}

detect_suspicious_patterns() {
  local file="$1"
  local patterns=(
    'sql.*injection|union.*select|1=1|or.*1=1'
    '\.\./|etc/passwd|etc/shadow'
    'cmd\.exe|powershell|wget.*http|curl.*http'
    'base64|eval\(|<script'
  )
  local found=0
  for pat in "${patterns[@]}"; do
    local hits
    hits=$(grep -ciP "$pat" "$file" 2>/dev/null || echo 0)
    if [[ $hits -gt 0 ]]; then
      printf "  ${RED}[SECURITY]${RESET} Pattern '%s' found %d times\n" "$pat" "$hits"
      found=1
    fi
  done
  [[ $found -eq 0 ]] && printf "  ${GREEN}No suspicious patterns detected${RESET}\n"
}

_section() { printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n" "$1"; }

analyze() {
  local file="$1" type="$2" outfile="${3:-}"
  local report=""

  printf "${BOLD}Log Anomaly Detector${RESET}  —  %s\n" "$(date '+%F %T')"
  printf "File  : %s\n" "$file"
  printf "Type  : %s\n" "$type"
  printf "Lines : %s\n" "$(wc -l < "$file")"

  _section "Error Rate (per minute)"
  local err_data
  err_data=$(count_errors_per_minute "$file" "$type")
  if [[ -z "$err_data" ]]; then
    printf "  ${GREEN}No errors detected${RESET}\n"
  else
    while IFS= read -r line; do
      local count minute
      count=$(echo "$line" | awk '{print $1}')
      minute=$(echo "$line" | awk '{print $2}')
      if [[ $count -ge $ERROR_THRESHOLD ]]; then
        printf "  ${RED}%s  %s errors${RESET} <- SPIKE\n" "$minute" "$count"
      else
        printf "  %s  %s errors\n" "$minute" "$count"
      fi
    done <<< "$err_data"
  fi

  if [[ "$type" == "nginx" || "$type" == "apache" ]]; then
    _section "HTTP Status Codes"
    extract_status_codes "$file" | while IFS= read -r line; do
      printf "  %s\n" "$line"
    done

    _section "Top IPs"
    extract_top_ips "$file" | while IFS= read -r line; do
      printf "  %s\n" "$line"
    done

    _section "IP Flood Detection (>100 req)"
    local flood
    flood=$(detect_ip_flood "$file")
    [[ -z "$flood" ]] && printf "  ${GREEN}No flood detected${RESET}\n" || echo "$flood"

    _section "Response Time Analysis"
    local lat
    lat=$(extract_latency "$file")
    [[ -z "$lat" ]] && printf "  N/A (no timing data found)\n" || printf "  %s\n" "$lat"
  fi

  _section "Security Pattern Scan"
  detect_suspicious_patterns "$file"

  _section "Recent Errors (last 10)"
  extract_errors "$file" "$type" | tail -10 | while IFS= read -r line; do
    printf "  ${YELLOW}%s${RESET}\n" "$line"
  done

  if [[ -n "$outfile" ]]; then
    {
      echo "# Log Anomaly Report"
      echo "**File:** \`$file\`  **Type:** $type  **Date:** $(date '+%F %T')"
      echo ""
      echo "Generated by log-anomaly-detector.sh"
    } > "$outfile"
    printf "\n${GREEN}Report saved to: %s${RESET}\n" "$outfile"
  fi
}

follow_mode() {
  local file="$1" type="$2"
  printf "${BOLD}Following log: %s${RESET} (Ctrl+C to stop)\n\n" "$file"
  tail -f "$file" | while IFS= read -r line; do
    if echo "$line" | grep -qiE '\b(error|fatal|critical|panic|exception)\b'; then
      printf "${RED}[ERROR]${RESET} %s\n" "$line"
    elif echo "$line" | grep -qiE '\b(warn|warning)\b'; then
      printf "${YELLOW}[WARN] ${RESET} %s\n" "$line"
    else
      printf "%s\n" "$line"
    fi
  done
}

main() {
  local logfile="" type="auto" follow=false outfile=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--type)     type="$2"; shift 2 ;;
      -w|--window)   WINDOW_SECONDS="$2"; shift 2 ;;
      -e|--errors)   ERROR_THRESHOLD="$2"; shift 2 ;;
      -l|--latency)  LATENCY_THRESHOLD="$2"; shift 2 ;;
      -f|--follow)   follow=true; shift ;;
      -o|--output)   outfile="$2"; shift 2 ;;
      -h|--help)     usage ;;
      *)             logfile="$1"; shift ;;
    esac
  done

  [[ -z "$logfile" ]] && logfile="$DEFAULT_LOG"
  [[ ! -f "$logfile" ]] && { printf "${RED}Error: file not found: %s${RESET}\n" "$logfile" >&2; exit 1; }

  [[ "$type" == "auto" ]] && type=$(detect_type "$logfile")

  if $follow; then
    follow_mode "$logfile" "$type"
  else
    analyze "$logfile" "$type" "$outfile"
  fi
}

main "$@"
