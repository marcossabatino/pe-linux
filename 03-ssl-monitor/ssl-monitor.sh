#!/usr/bin/env bash
# SSL Certificate Monitor — checks expiry across multiple domains with alerting
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

WARN_DAYS="${WARN_DAYS:-30}"
CRIT_DAYS="${CRIT_DAYS:-7}"
TIMEOUT="${TIMEOUT:-10}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"  # table|json|csv

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] <domain[:port]> [domain2] ...
       $0 [OPTIONS] --file domains.txt

Options:
  -f, --file     File with one domain per line
  -w, --warn     Days until expiry to warn (default: ${WARN_DAYS})
  -c, --crit     Days until expiry to alert critical (default: ${CRIT_DAYS})
  -t, --timeout  Connection timeout in seconds (default: ${TIMEOUT})
  -o, --output   Output format: table|json|csv (default: table)
  -s, --slack    Slack webhook URL for alerts
  -q, --quiet    Only show warnings/errors
  -h, --help     Show this help

Examples:
  $0 google.com github.com
  $0 --file /etc/ssl-monitor/domains.txt --slack https://hooks.slack.com/...
  $0 mysite.com:8443 --output json
EOF
  exit 0
}

check_domain() {
  local domain="$1" port="${2:-443}"
  local now days_left expiry issuer subject status color

  now=$(date +%s)

  local cert_info
  cert_info=$(echo | timeout "$TIMEOUT" openssl s_client \
    -connect "${domain}:${port}" \
    -servername "$domain" \
    2>/dev/null) || { echo "CONN_FAILED|||${domain}|${port}"; return; }

  expiry=$(echo "$cert_info" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  subject=$(echo "$cert_info" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
  issuer=$(echo "$cert_info" | openssl x509 -noout -issuer 2>/dev/null | grep -oP 'O = [^,]+' | head -1 | cut -d= -f2 | xargs)

  [[ -z "$expiry" ]] && { echo "PARSE_ERROR|||${domain}|${port}"; return; }

  local expiry_epoch
  expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null)
  days_left=$(( (expiry_epoch - now) / 86400 ))

  if [[ $days_left -le 0 ]]; then
    status="EXPIRED"; color=$RED
  elif [[ $days_left -le $CRIT_DAYS ]]; then
    status="CRITICAL"; color=$RED
  elif [[ $days_left -le $WARN_DAYS ]]; then
    status="WARNING"; color=$YELLOW
  else
    status="OK"; color=$GREEN
  fi

  echo "${status}|${days_left}|${expiry}|${domain}|${port}|${issuer:-unknown}|${color}"
}

send_slack() {
  local webhook="$1" message="$2"
  [[ -z "$webhook" ]] && return
  curl -s -X POST "$webhook" \
    -H 'Content-type: application/json' \
    --data "{\"text\":\"${message}\"}" > /dev/null
}

render_table() {
  local results=("$@")
  printf "\n${BOLD}%-35s %-10s %-5s %-30s %-20s${RESET}\n" \
    "DOMAIN" "STATUS" "DAYS" "EXPIRES" "ISSUER"
  printf '%0.s-' {1..105}; echo

  for row in "${results[@]}"; do
    IFS='|' read -r status days expiry domain port issuer color <<< "$row"
    printf "${color}%-35s %-10s %-5s %-30s %-20s${RESET}\n" \
      "${domain}:${port}" "$status" "$days" "$expiry" "$issuer"
  done
}

render_json() {
  local results=("$@")
  echo "["
  local first=true
  for row in "${results[@]}"; do
    IFS='|' read -r status days expiry domain port issuer color <<< "$row"
    $first || echo ","
    printf '  {"domain":"%s","port":%s,"status":"%s","days_left":%s,"expiry":"%s","issuer":"%s"}' \
      "$domain" "$port" "$status" "$days" "$expiry" "$issuer"
    first=false
  done
  echo -e "\n]"
}

render_csv() {
  local results=("$@")
  echo "domain,port,status,days_left,expiry,issuer"
  for row in "${results[@]}"; do
    IFS='|' read -r status days expiry domain port issuer color <<< "$row"
    echo "${domain},${port},${status},${days},${expiry},${issuer}"
  done
}

main() {
  local domains=() domainfile="" quiet=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)    domainfile="$2"; shift 2 ;;
      -w|--warn)    WARN_DAYS="$2"; shift 2 ;;
      -c|--crit)    CRIT_DAYS="$2"; shift 2 ;;
      -t|--timeout) TIMEOUT="$2"; shift 2 ;;
      -o|--output)  OUTPUT_FORMAT="$2"; shift 2 ;;
      -s|--slack)   SLACK_WEBHOOK="$2"; shift 2 ;;
      -q|--quiet)   quiet=true; shift ;;
      -h|--help)    usage ;;
      *)            domains+=("$1"); shift ;;
    esac
  done

  if [[ -n "$domainfile" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      domains+=("$line")
    done < "$domainfile"
  fi

  [[ ${#domains[@]} -eq 0 ]] && { echo "No domains specified. Use --help for usage."; exit 1; }

  printf "${BOLD}SSL Certificate Monitor${RESET}  —  %s\n" "$(date '+%F %T')"
  printf "Checking %d domain(s)  |  warn: %dd  crit: %dd\n" "${#domains[@]}" "$WARN_DAYS" "$CRIT_DAYS"

  local results=() alerts=()

  for entry in "${domains[@]}"; do
    local domain port
    if [[ "$entry" == *:* ]]; then
      domain="${entry%%:*}"
      port="${entry##*:}"
    else
      domain="$entry"
      port="443"
    fi

    printf "  Checking %-40s" "${domain}:${port} ..."
    local result
    result=$(check_domain "$domain" "$port")
    local status
    status=$(echo "$result" | cut -d'|' -f1)

    case "$status" in
      OK)       printf "${GREEN}OK${RESET}\n" ;;
      WARNING)  printf "${YELLOW}WARNING${RESET}\n" ;;
      CRITICAL|EXPIRED) printf "${RED}%s${RESET}\n" "$status" ;;
      *)        printf "${RED}FAILED${RESET}\n" ;;
    esac

    results+=("$result")
    [[ "$status" != "OK" && "$status" != "CONN_FAILED" ]] && alerts+=("$result")
  done

  echo ""
  case "$OUTPUT_FORMAT" in
    json) render_json "${results[@]}" ;;
    csv)  render_csv  "${results[@]}" ;;
    *)    render_table "${results[@]}" ;;
  esac

  if [[ ${#alerts[@]} -gt 0 && -n "$SLACK_WEBHOOK" ]]; then
    local msg="*SSL Certificate Alert* ($(date '+%F'))\n"
    for alert in "${alerts[@]}"; do
      IFS='|' read -r status days expiry domain port issuer _ <<< "$alert"
      msg+="• ${domain}:${port} — *${status}* (${days} days)\n"
    done
    send_slack "$SLACK_WEBHOOK" "$msg"
    printf "\n${GREEN}Slack alert sent.${RESET}\n"
  fi

  local exit_code=0
  for r in "${results[@]}"; do
    local s; s=$(echo "$r" | cut -d'|' -f1)
    [[ "$s" == "CRITICAL" || "$s" == "EXPIRED" ]] && exit_code=2 && break
    [[ "$s" == "WARNING" ]] && exit_code=1
  done
  exit $exit_code
}

main "$@"
