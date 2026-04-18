#!/usr/bin/env bash
# Incident Runbook Automator — executes triage checklist and generates a structured report
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

REPORT_DIR="${REPORT_DIR:-/tmp/incident-reports}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
TIMEOUT="${TIMEOUT:-10}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] --service <name> [--url <healthcheck_url>]

Options:
  -s, --service    Service/application name (required)
  -u, --url        Service healthcheck URL
  --severity       Incident severity: P1|P2|P3 (default: P2)
  --reporter       Who is running this triage
  --slack          Slack webhook for report summary
  --report-dir     Directory to save reports (default: ${REPORT_DIR})
  --dry-run        Print steps without executing
  -h, --help       Show this help

Examples:
  $0 --service api-gateway --url http://api.internal/health --severity P1
  $0 --service payment-service --reporter "on-call: alice" --slack https://hooks.slack.com/...
EOF
  exit 0
}

SERVICE=""
SERVICE_URL=""
SEVERITY="P2"
REPORTER="${USER:-unknown}"
DRY_RUN=false
REPORT_FILE=""
REPORT_CONTENT=""

_ts()      { date '+%F %T'; }
_section() { printf "\n${BOLD}${CYAN}>>> %s${RESET}\n" "$1"; }
_step()    { printf "  ${BOLD}[%s]${RESET} %s\n" "$(_ts)" "$*"; }
_ok()      { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
_warn()    { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
_err()     { printf "  ${RED}✗${RESET} %s\n" "$*"; }

_append() { REPORT_CONTENT+="$*"$'\n'; }

_run() {
  local label="$1"; shift
  local cmd="$*"
  _step "$label"
  if $DRY_RUN; then
    printf "    ${CYAN}[DRY-RUN]${RESET} %s\n" "$cmd"
    _append "### $label"
    _append "\`\`\`"
    _append "[DRY-RUN] $cmd"
    _append "\`\`\`"
    return
  fi
  local output exit_code=0
  output=$(eval "$cmd" 2>&1) || exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    _ok "Done"
  else
    _warn "Command exited with code $exit_code"
  fi
  _append "### $label"
  _append "\`\`\`"
  _append "$output"
  _append "\`\`\`"
  printf "%s\n" "$output" | head -20 | sed 's/^/    /'
  [[ $(echo "$output" | wc -l) -gt 20 ]] && printf "    ... (truncated)\n"
}

_notify() {
  [[ -z "$SLACK_WEBHOOK" ]] && return
  curl -s -X POST "$SLACK_WEBHOOK" \
    -H 'Content-type: application/json' \
    --data "{\"text\":\"$1\"}" > /dev/null || true
}

triage_system() {
  _section "1. System Overview"
  _run "Hostname & Uptime"      "hostname -f; uptime"
  _run "OS & Kernel"            "uname -a; cat /etc/os-release | grep PRETTY"
  _run "Current Date/Time"      "date; timedatectl status 2>/dev/null | grep -E 'Local|sync'"
  _run "Load Average"           "cat /proc/loadavg"
  _run "CPU Usage"              "top -bn1 | head -15"
  _run "Memory Usage"           "free -h"
  _run "Disk Usage"             "df -h --output=target,used,avail,pcent | grep -v tmpfs"
}

triage_processes() {
  _section "2. Process Health"
  _run "Top CPU Processes"      "ps axo pid,user,%cpu,%mem,stat,comm --sort=-%cpu | head -15"
  _run "Top Memory Processes"   "ps axo pid,user,%cpu,%mem,rss,comm --sort=-rss | head -10"
  _run "Zombie Processes"       "ps axo pid,ppid,stat,comm | awk '\$3~/^Z/' || echo 'none'"
  _run "OOM Killer Events"      "dmesg --ctime 2>/dev/null | grep -i 'oom\|killed process' | tail -10 || journalctl -k --no-pager 2>/dev/null | grep -i 'oom' | tail -10 || echo 'none'"

  if [[ -n "$SERVICE" ]]; then
    _run "Service process" "pgrep -la '$SERVICE' || echo 'process not found'"
    if systemctl list-units --type=service 2>/dev/null | grep -q "$SERVICE"; then
      _run "Systemd service status" "systemctl status '$SERVICE' --no-pager 2>/dev/null || true"
    fi
  fi
}

triage_logs() {
  _section "3. Recent Logs"
  _run "Kernel errors (last 30min)"  "journalctl -k --no-pager --since '30 minutes ago' 2>/dev/null | grep -iE 'error|warn|crit' | tail -20 || dmesg --ctime | grep -iE 'error|warn' | tail -20 || echo 'N/A'"
  _run "Auth failures (last 30min)"  "journalctl -u sshd --no-pager --since '30 minutes ago' 2>/dev/null | grep -i 'failed\|invalid' | tail -10 || grep 'Failed\|Invalid' /var/log/auth.log 2>/dev/null | tail -10 || echo 'N/A'"

  if [[ -n "$SERVICE" ]]; then
    _run "Service logs (last 50 lines)" \
      "journalctl -u '$SERVICE' --no-pager --since '1 hour ago' 2>/dev/null | grep -iE 'error|warn|exception|fatal|panic|crit' | tail -50 || echo 'journald not available or service not found'"
  fi

  for logfile in /var/log/nginx/error.log /var/log/apache2/error.log /var/log/app.log /var/log/syslog; do
    [[ -f "$logfile" ]] && \
      _run "$(basename $logfile) errors (tail 10)" "tail -10 '$logfile' | grep -iE 'error|warn|crit' || echo 'no recent errors'"
  done
}

triage_network() {
  _section "4. Network"
  _run "Network interfaces"  "ip -br addr show"
  _run "Routing table"       "ip route show"
  _run "DNS resolution"      "dig +short google.com 2>/dev/null || nslookup google.com 2>/dev/null | tail -5 || echo 'dig/nslookup not available'"
  _run "Listening ports"     "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo 'N/A'"
  _run "Connection states"   "ss -tan 2>/dev/null | awk 'NR>1{c[\$1]++} END{for(s in c) print s, c[s]}' | sort -k2 -rn || echo 'N/A'"
  _run "Recent connection errors" "dmesg --ctime 2>/dev/null | grep -iE 'nf_conntrack|connection refused|unreachable' | tail -10 || echo 'none'"

  if [[ -n "$SERVICE_URL" ]]; then
    _run "Service healthcheck" \
      "curl -v -s -o /dev/null -w 'HTTP %{http_code}  time_total=%{time_total}s' --max-time $TIMEOUT '$SERVICE_URL' 2>&1 || echo 'FAILED'"
  fi
}

triage_storage() {
  _section "5. Storage & I/O"
  _run "Disk I/O stats"    "iostat -xz 1 3 2>/dev/null | tail -20 || echo 'iostat not available'"
  _run "Inode usage"       "df -i --output=target,iused,iavail,ipcent | grep -v tmpfs"
  _run "Recent disk errors" "dmesg --ctime 2>/dev/null | grep -iE 'I/O error|disk error|sector' | tail -10 || echo 'none'"
  _run "Large files (>1GB)" "find / -xdev -size +1G -printf '%s %p\n' 2>/dev/null | sort -rn | head -10 | awk '{printf \"%dGB  %s\n\", \$1/1073741824, \$2}' || echo 'N/A'"
}

generate_report() {
  mkdir -p "$REPORT_DIR"
  local ts; ts=$(date '+%Y%m%d_%H%M%S')
  REPORT_FILE="${REPORT_DIR}/incident-${SERVICE:-host}-${ts}.md"

  {
    echo "# Incident Triage Report"
    echo ""
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Service | ${SERVICE:-N/A} |"
    echo "| Severity | ${SEVERITY} |"
    echo "| Reporter | ${REPORTER} |"
    echo "| Host | $(hostname -f 2>/dev/null || hostname) |"
    echo "| Date | $(_ts) |"
    echo "| URL | ${SERVICE_URL:-N/A} |"
    echo ""
    echo "---"
    echo ""
    echo "$REPORT_CONTENT"
    echo ""
    echo "---"
    echo "*Generated by incident-runbook.sh*"
  } > "$REPORT_FILE"

  printf "\n${GREEN}${BOLD}Report saved: %s${RESET}\n" "$REPORT_FILE"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--service)    SERVICE="$2"; shift 2 ;;
      -u|--url)        SERVICE_URL="$2"; shift 2 ;;
      --severity)      SEVERITY="$2"; shift 2 ;;
      --reporter)      REPORTER="$2"; shift 2 ;;
      --slack)         SLACK_WEBHOOK="$2"; shift 2 ;;
      --report-dir)    REPORT_DIR="$2"; shift 2 ;;
      --dry-run)       DRY_RUN=true; shift ;;
      -h|--help)       usage ;;
      *)               shift ;;
    esac
  done

  [[ -z "$SERVICE" ]] && { printf "${RED}--service is required${RESET}\n"; usage; }

  local sev_color=$YELLOW
  [[ "$SEVERITY" == "P1" ]] && sev_color=$RED
  [[ "$SEVERITY" == "P3" ]] && sev_color=$GREEN

  printf "\n${BOLD}Incident Runbook Automator${RESET}\n"
  printf "  Service  : %s\n" "$SERVICE"
  printf "  Severity : ${sev_color}%s${RESET}\n" "$SEVERITY"
  printf "  Reporter : %s\n" "$REPORTER"
  printf "  Time     : %s\n\n" "$(_ts)"

  _notify ":rotating_light: *Incident Triage Started* | Service: *${SERVICE}* | Severity: *${SEVERITY}* | By: ${REPORTER}"

  _append "## Triage Started: $(_ts)"

  triage_system
  triage_processes
  triage_logs
  triage_network
  triage_storage

  generate_report

  local summary
  summary=":white_check_mark: *Incident Triage Complete* | Service: *${SERVICE}* | Severity: *${SEVERITY}* | Report: \`${REPORT_FILE}\`"
  _notify "$summary"

  printf "\n${BOLD}Summary:${RESET} Triage complete. Report at: ${CYAN}%s${RESET}\n" "$REPORT_FILE"
}

main "$@"
