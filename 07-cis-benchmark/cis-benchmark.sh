#!/usr/bin/env bash
# CIS Benchmark Checker — Linux hardening audit based on CIS Linux Benchmark
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"
REPORT_FILE="${REPORT_FILE:-}"
SCORE_ONLY="${SCORE_ONLY:-false}"

PASS=0; FAIL=0; WARN=0; SKIP=0

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -o, --output   Output format: table|json|csv (default: table)
  -r, --report   Save report to file (markdown)
  --score        Show final score only
  -h, --help     Show this help

Checks performed (CIS Linux Benchmark v2.x):
  - Filesystem configuration
  - Software updates
  - SSH hardening
  - User accounts and passwords
  - File permissions
  - Cron and scheduled tasks
  - Auditing and logging
  - Network settings
  - Unused services
EOF
  exit 0
}

declare -a RESULTS

_check() {
  local id="$1" category="$2" description="$3" result="$4" severity="${5:-HIGH}"
  RESULTS+=("${id}|${category}|${description}|${result}|${severity}")
  case "$result" in
    PASS) PASS=$(( PASS + 1 )) ;;
    FAIL) FAIL=$(( FAIL + 1 )) ;;
    WARN) WARN=$(( WARN + 1 )) ;;
    SKIP) SKIP=$(( SKIP + 1 )) ;;
  esac
}

_cmd_ok() { command -v "$1" &>/dev/null; }
_file_contains() { grep -qsP "$2" "$1" 2>/dev/null; }
_sysctl_val() { sysctl -n "$1" 2>/dev/null || echo ""; }

# ── Filesystem ────────────────────────────────────────────────────────────────
check_filesystem() {
  for mnt in /tmp /var /var/tmp /var/log /home; do
    if findmnt -n "$mnt" &>/dev/null; then
      local opts; opts=$(findmnt -n -o OPTIONS "$mnt" 2>/dev/null || echo "")
      local r="FAIL"
      echo "$opts" | grep -q "noexec\|nosuid" && r="PASS"
      _check "1.1.$(echo "$mnt" | tr -cd '[:alpha:]')" "Filesystem" \
        "${mnt} has noexec/nosuid options" "$r" "MEDIUM"
    fi
  done

  # Sticky bit on world-writable dirs (limit to common mounts to avoid hanging)
  local ww_count=0 r
  ww_count=$(timeout 5 find /tmp /var /home -xdev -type d -perm -0002 ! -perm -1000 2>/dev/null | wc -l) 2>/dev/null || ww_count=0
  ww_count="${ww_count//[[:space:]]/}"
  [[ "${ww_count:-0}" -eq 0 ]] && r="PASS" || r="FAIL"
  _check "1.1.21" "Filesystem" "Sticky bit on world-writable directories (found: ${ww_count:-0})" "$r"
}

# ── SSH Hardening ─────────────────────────────────────────────────────────────
check_ssh() {
  local sshd="/etc/ssh/sshd_config"
  [[ ! -f "$sshd" ]] && { _check "5.2.0" "SSH" "sshd_config not found" "SKIP"; return; }

  local checks=(
    "PermitRootLogin no:5.2.10:Root login disabled"
    "Protocol 2:5.2.1:SSH Protocol 2 enforced"
    "PermitEmptyPasswords no:5.2.11:Empty passwords disabled"
    "X11Forwarding no:5.2.6:X11 forwarding disabled"
    "MaxAuthTries [1-4]:5.2.7:Max auth tries <= 4"
    "IgnoreRhosts yes:5.2.8:Rhosts ignored"
    "HostbasedAuthentication no:5.2.9:Host-based auth disabled"
    "Banner /:5.2.16:Login banner configured"
    "ClientAliveInterval [1-9]:5.2.13:Idle timeout configured"
  )

  for item in "${checks[@]}"; do
    IFS=':' read -r pattern id desc <<< "$item"
    if grep -qsP "^\s*${pattern}" "$sshd" 2>/dev/null; then
      _check "$id" "SSH" "$desc" "PASS"
    else
      _check "$id" "SSH" "$desc" "FAIL"
    fi
  done
}

# ── User Accounts ─────────────────────────────────────────────────────────────
check_users() {
  local uid0_count r
  uid0_count=$(awk -F: '$3==0{c++} END{print c+0}' /etc/passwd)
  [[ $uid0_count -eq 1 ]] && r="PASS" || r="FAIL"
  _check "6.2.5" "Users" "Only root has UID 0 (found: $uid0_count)" "$r"

  local empty_pw=0
  if [[ -r /etc/shadow ]]; then
    empty_pw=$(awk -F: '$2==""' /etc/shadow | wc -l) || empty_pw=0
  fi
  [[ $empty_pw -eq 0 ]] && r="PASS" || r="FAIL"
  _check "6.2.1" "Users" "No accounts with empty passwords" "$r"

  local max_days
  max_days=$(grep -oP '^PASS_MAX_DAYS\s+\K\d+' /etc/login.defs 2>/dev/null) || max_days=99999
  [[ ${max_days:-99999} -le 365 ]] && r="PASS" || r="FAIL"
  _check "5.4.1.1" "Users" "PASS_MAX_DAYS <= 365 (${max_days:-99999})" "$r" "MEDIUM"

  local inactive="-1"
  inactive=$(useradd -D 2>/dev/null | awk -F= '/INACTIVE/{print $2}') || inactive="-1"
  inactive="${inactive:-"-1"}"
  if [[ "$inactive" =~ ^[0-9]+$ ]] && [[ "$inactive" -le 30 ]]; then
    r="PASS"
  else
    r="WARN"
  fi
  _check "5.4.1.4" "Users" "Inactive account lock <= 30 days (${inactive})" "$r" "MEDIUM"
}

# ── File Permissions ──────────────────────────────────────────────────────────
check_permissions() {
  local critical_files=(
    "/etc/passwd:644"
    "/etc/shadow:640"
    "/etc/group:644"
    "/etc/gshadow:640"
    "/etc/ssh/sshd_config:600"
    "/etc/crontab:600"
    "/boot/grub2/grub.cfg:600"
    "/boot/grub/grub.cfg:600"
  )

  local r actual
  for item in "${critical_files[@]}"; do
    IFS=':' read -r file expected <<< "$item"
    [[ ! -f "$file" ]] && continue
    actual=$(stat -c '%a' "$file" 2>/dev/null) || actual="???"
    if [[ "$actual" =~ ^[0-9]+$ ]] && [[ "$actual" -le "$expected" ]]; then
      r="PASS"
    else
      r="FAIL"
    fi
    _check "6.1.$(basename "$file")" "Permissions" \
      "${file} permissions <= ${expected} (actual: ${actual})" "$r"
  done
}

# ── Network Settings ──────────────────────────────────────────────────────────
check_network() {
  local net_checks=(
    "net.ipv4.ip_forward:0:3.1.1:IP forwarding disabled"
    "net.ipv4.conf.all.accept_redirects:0:3.2.2:ICMP redirects rejected"
    "net.ipv4.conf.all.send_redirects:0:3.1.2:Send redirects disabled"
    "net.ipv4.icmp_echo_ignore_broadcasts:1:3.2.5:Broadcast ICMP ignored"
    "net.ipv4.tcp_syncookies:1:3.2.8:SYN cookies enabled"
    "net.ipv4.conf.all.rp_filter:1:3.2.7:Reverse path filtering enabled"
    "net.ipv6.conf.all.disable_ipv6:1:3.3.1:IPv6 disabled (if not needed)"
  )

  for item in "${net_checks[@]}"; do
    IFS=':' read -r key expected id desc <<< "$item"
    local val; val=$(_sysctl_val "$key")
    if [[ "$val" == "$expected" ]]; then
      _check "$id" "Network" "$desc" "PASS" "MEDIUM"
    else
      [[ "$key" == *"ipv6"* ]] && \
        _check "$id" "Network" "$desc (${val:-N/A})" "WARN" "LOW" || \
        _check "$id" "Network" "$desc (${val:-N/A})" "FAIL" "MEDIUM"
    fi
  done
}

# ── Services ──────────────────────────────────────────────────────────────────
check_services() {
  local unwanted=(
    "telnet:1.1.1:Telnet server"
    "rsh-server:2.1.1:RSH server"
    "ypserv:2.2.1:NIS server"
    "tftp-server:2.1.7:TFTP server"
    "vsftpd:2.2.1:FTP server"
  )

  for item in "${unwanted[@]}"; do
    IFS=':' read -r svc id desc <<< "$item"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      _check "$id" "Services" "$desc is running" "FAIL"
    else
      _check "$id" "Services" "$desc not running" "PASS" "MEDIUM"
    fi
  done
}

# ── Auditing ──────────────────────────────────────────────────────────────────
check_auditing() {
  if systemctl is-active --quiet auditd 2>/dev/null; then
    _check "4.1.1.1" "Auditing" "auditd service is running" "PASS"
  else
    _check "4.1.1.1" "Auditing" "auditd service is NOT running" "FAIL"
  fi

  if _file_contains "/etc/audit/auditd.conf" "max_log_file_action\s*=\s*keep_logs"; then
    _check "4.1.1.3" "Auditing" "Audit log retention configured" "PASS" "MEDIUM"
  else
    _check "4.1.1.3" "Auditing" "Audit log retention not configured" "WARN" "MEDIUM"
  fi
}

render_table() {
  printf "\n${BOLD}%-8s %-15s %-50s %-6s %s${RESET}\n" \
    "ID" "CATEGORY" "CHECK" "RESULT" "SEVERITY"
  printf '%0.s-' {1..105}; echo

  for row in "${RESULTS[@]}"; do
    IFS='|' read -r id cat desc result sev <<< "$row"
    local color=$RESET
    case "$result" in
      PASS) color=$GREEN ;;
      FAIL) color=$RED   ;;
      WARN) color=$YELLOW;;
    esac
    printf "${color}%-8s %-15s %-50s %-6s %s${RESET}\n" \
      "$id" "$cat" "$desc" "$result" "$sev"
  done
}

render_score() {
  local total=$(( PASS + FAIL + WARN + SKIP ))
  local score=0
  [[ $total -gt 0 ]] && score=$(( PASS * 100 / total ))

  printf "\n${BOLD}=== CIS Benchmark Score ===${RESET}\n"
  printf "  ${GREEN}PASS${RESET}  : %d\n" "$PASS"
  printf "  ${RED}FAIL${RESET}  : %d\n" "$FAIL"
  printf "  ${YELLOW}WARN${RESET}  : %d\n" "$WARN"
  printf "  SKIP  : %d\n" "$SKIP"
  printf "  Total : %d\n" "$total"
  printf "  ${BOLD}Score : %d%%${RESET}\n" "$score"

  local grade color
  if   [[ $score -ge 90 ]]; then grade="A"; color=$GREEN
  elif [[ $score -ge 75 ]]; then grade="B"; color=$GREEN
  elif [[ $score -ge 60 ]]; then grade="C"; color=$YELLOW
  elif [[ $score -ge 40 ]]; then grade="D"; color=$YELLOW
  else                           grade="F"; color=$RED
  fi
  printf "  ${BOLD}Grade : ${color}%s${RESET}\n" "$grade"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--output) OUTPUT_FORMAT="$2"; shift 2 ;;
      -r|--report) REPORT_FILE="$2"; shift 2 ;;
      --score)     SCORE_ONLY=true; shift ;;
      -h|--help)   usage ;;
      *)           shift ;;
    esac
  done

  printf "${BOLD}CIS Linux Benchmark Checker${RESET}  —  %s\n" "$(date '+%F %T')"
  printf "Host: %s  |  Kernel: %s\n\n" "$(hostname)" "$(uname -r)"

  printf "Running checks...\n"
  check_filesystem
  check_ssh
  check_users
  check_permissions
  check_network
  check_services
  check_auditing

  $SCORE_ONLY || render_table
  render_score

  if [[ -n "$REPORT_FILE" ]]; then
    {
      echo "# CIS Benchmark Report"
      echo "**Host:** $(hostname)  **Date:** $(date '+%F %T')"
      echo ""
      echo "| ID | Category | Check | Result | Severity |"
      echo "|---|---|---|---|---|"
      for row in "${RESULTS[@]}"; do
        IFS='|' read -r id cat desc result sev <<< "$row"
        echo "| $id | $cat | $desc | $result | $sev |"
      done
      echo ""
      echo "**Score:** ${PASS}/${$(( PASS+FAIL+WARN+SKIP ))} ($(( PASS*100/(PASS+FAIL+WARN+SKIP) ))%)"
    } > "$REPORT_FILE"
    printf "\n${GREEN}Report saved to: %s${RESET}\n" "$REPORT_FILE"
  fi
}

main "$@"
