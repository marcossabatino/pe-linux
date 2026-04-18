#!/usr/bin/env bash
# Kubernetes Pod Health Checker — detects unhealthy pods and surfaces actionable context
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

NAMESPACE="${NAMESPACE:-}"
CONTEXT="${KUBE_CONTEXT:-}"
RESTART_THRESHOLD="${RESTART_THRESHOLD:-5}"
PENDING_THRESHOLD_MIN="${PENDING_THRESHOLD_MIN:-10}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -n, --namespace  Kubernetes namespace (default: all)
  -c, --context    Kubeconfig context to use
  -r, --restarts   Restart count threshold for alert (default: ${RESTART_THRESHOLD})
  -p, --pending    Minutes a pod can be Pending before alert (default: ${PENDING_THRESHOLD_MIN})
  -s, --slack      Slack webhook URL
  -o, --output     Output format: table|json (default: table)
  -w, --watch      Watch mode (refresh every 15s)
  -h, --help       Show this help

Examples:
  $0 --namespace production
  $0 -n kube-system --context staging-cluster
  $0 --watch --slack https://hooks.slack.com/...
EOF
  exit 0
}

kubectl_cmd() {
  local cmd=(kubectl)
  [[ -n "$CONTEXT"   ]] && cmd+=(--context "$CONTEXT")
  [[ -n "$NAMESPACE" ]] && cmd+=(-n "$NAMESPACE") || cmd+=(--all-namespaces)
  "${cmd[@]}" "$@"
}

check_pods() {
  kubectl_cmd get pods -o json 2>/dev/null
}

parse_pods() {
  local json="$1"
  echo "$json" | python3 -c "
import json, sys, datetime

data = json.load(sys.stdin)
items = data.get('items', [])
now = datetime.datetime.utcnow()

for pod in items:
  meta  = pod.get('metadata', {})
  spec  = pod.get('spec', {})
  status = pod.get('status', {})

  name      = meta.get('name', 'unknown')
  namespace = meta.get('namespace', 'default')
  phase     = status.get('phase', 'Unknown')
  node      = spec.get('nodeName', '<none>')

  restarts = 0
  container_statuses = status.get('containerStatuses', [])
  reasons = []

  for cs in container_statuses:
    restarts += cs.get('restartCount', 0)
    state = cs.get('state', {})
    waiting = state.get('waiting', {})
    if waiting:
      reasons.append(waiting.get('reason', ''))

  reason = ','.join(filter(None, reasons)) or phase

  # Pending duration
  pending_min = 0
  if phase == 'Pending':
    start = meta.get('creationTimestamp', '')
    if start:
      try:
        t = datetime.datetime.strptime(start, '%Y-%m-%dT%H:%M:%SZ')
        pending_min = int((now - t).total_seconds() / 60)
      except:
        pass

  print(f'{namespace}|{name}|{phase}|{reason}|{restarts}|{node}|{pending_min}')
" 2>/dev/null || {
    # Fallback without python3
    kubectl_cmd get pods --no-headers -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName' \
      2>/dev/null | awk '{print $1"|"$2"|"$3"|"$3"|"$4"|"$5"|0"}'
  }
}

_section() { printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n" "$1"; }

analyze() {
  local json pod_data
  printf "Fetching pod data...\n"
  json=$(check_pods)
  pod_data=$(parse_pods "$json")

  local total=0 healthy=0 warnings=() criticals=()

  while IFS='|' read -r ns name phase reason restarts node pending_min; do
    (( total++ ))
    local issues=()
    local severity="ok"

    case "$phase" in
      Running|Succeeded) : ;;
      Failed)   issues+=("Phase: Failed"); severity="crit" ;;
      Pending)
        [[ $pending_min -ge $PENDING_THRESHOLD_MIN ]] && {
          issues+=("Pending for ${pending_min}m"); severity="crit"
        }
        ;;
      *)
        issues+=("Phase: $phase")
        severity="warn"
        ;;
    esac

    case "$reason" in
      CrashLoopBackOff) issues+=("CrashLoopBackOff"); severity="crit" ;;
      OOMKilled)        issues+=("OOMKilled"); severity="crit" ;;
      ImagePullBackOff|ErrImagePull) issues+=("Image pull failed"); severity="crit" ;;
      Error)            issues+=("Container error"); severity="warn" ;;
    esac

    [[ $restarts -ge $RESTART_THRESHOLD ]] && {
      issues+=("Restarts: $restarts")
      [[ "$severity" != "crit" ]] && severity="warn"
    }

    if [[ ${#issues[@]} -eq 0 ]]; then
      (( healthy++ ))
    else
      local issue_str
      issue_str=$(IFS=', '; echo "${issues[*]}")
      local row="${ns}|${name}|${phase}|${issue_str}|${restarts}|${node}"
      [[ "$severity" == "crit" ]] && criticals+=("$row") || warnings+=("$row")
    fi
  done <<< "$pod_data"

  clear
  printf "${BOLD}Kubernetes Pod Health Checker${RESET}  —  %s\n" "$(date '+%F %T')"
  [[ -n "$NAMESPACE" ]] && printf "Namespace: %s\n" "$NAMESPACE" || printf "Namespace: all\n"
  [[ -n "$CONTEXT"   ]] && printf "Context  : %s\n" "$CONTEXT"
  printf "Pods: ${GREEN}%d healthy${RESET} / %d total\n\n" "$healthy" "$total"

  if [[ ${#criticals[@]} -gt 0 ]]; then
    _section "CRITICAL (${#criticals[@]} pods)"
    printf "${BOLD}%-20s %-35s %-12s %-30s %s${RESET}\n" \
      "NAMESPACE" "POD" "PHASE" "ISSUES" "RESTARTS"
    printf '%0.s-' {1..110}; echo
    for row in "${criticals[@]}"; do
      IFS='|' read -r ns name phase issues restarts node <<< "$row"
      printf "${RED}%-20s %-35s %-12s %-30s %s${RESET}\n" \
        "$ns" "$name" "$phase" "$issues" "$restarts"
    done
  fi

  if [[ ${#warnings[@]} -gt 0 ]]; then
    _section "WARNING (${#warnings[@]} pods)"
    printf "${BOLD}%-20s %-35s %-12s %-30s %s${RESET}\n" \
      "NAMESPACE" "POD" "PHASE" "ISSUES" "RESTARTS"
    printf '%0.s-' {1..110}; echo
    for row in "${warnings[@]}"; do
      IFS='|' read -r ns name phase issues restarts node <<< "$row"
      printf "${YELLOW}%-20s %-35s %-12s %-30s %s${RESET}\n" \
        "$ns" "$name" "$phase" "$issues" "$restarts"
    done
  fi

  if [[ ${#criticals[@]} -eq 0 && ${#warnings[@]} -eq 0 ]]; then
    printf "${GREEN}All pods are healthy.${RESET}\n"
  fi

  if [[ ${#criticals[@]} -gt 0 || ${#warnings[@]} -gt 0 ]]; then
    _section "Suggested Actions"
    for row in "${criticals[@]}" "${warnings[@]}"; do
      IFS='|' read -r ns name phase issues restarts node <<< "$row"
      printf "\n  Pod: %s/%s\n" "$ns" "$name"
      if echo "$issues" | grep -q "CrashLoop"; then
        printf "    kubectl logs -n %s %s --previous\n" "$ns" "$name"
        printf "    kubectl describe pod -n %s %s\n" "$ns" "$name"
      elif echo "$issues" | grep -q "OOMKilled"; then
        printf "    Increase memory limit in deployment spec\n"
        printf "    kubectl describe pod -n %s %s | grep -A5 Limits\n" "$ns" "$name"
      elif echo "$issues" | grep -q "Image"; then
        printf "    kubectl describe pod -n %s %s | grep -A3 Events\n" "$ns" "$name"
      fi
    done
  fi

  if [[ -n "$SLACK_WEBHOOK" && ( ${#criticals[@]} -gt 0 || ${#warnings[@]} -gt 0 ) ]]; then
    local msg="*K8s Pod Health Alert* — $(date '+%F %T')\n"
    msg+="${#criticals[@]} critical  |  ${#warnings[@]} warnings\n"
    for row in "${criticals[@]}"; do
      IFS='|' read -r ns name phase issues restarts _ <<< "$row"
      msg+=":red_circle: \`${ns}/${name}\` — ${issues}\n"
    done
    curl -s -X POST "$SLACK_WEBHOOK" \
      -H 'Content-type: application/json' \
      --data "{\"text\":\"${msg}\"}" > /dev/null
    printf "\n${GREEN}Slack alert sent.${RESET}\n"
  fi
}

main() {
  local watch=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace) NAMESPACE="$2"; shift 2 ;;
      -c|--context)   CONTEXT="$2"; shift 2 ;;
      -r|--restarts)  RESTART_THRESHOLD="$2"; shift 2 ;;
      -p|--pending)   PENDING_THRESHOLD_MIN="$2"; shift 2 ;;
      -s|--slack)     SLACK_WEBHOOK="$2"; shift 2 ;;
      -o|--output)    OUTPUT_FORMAT="$2"; shift 2 ;;
      -w|--watch)     watch=true; shift ;;
      -h|--help)      usage ;;
      *)              shift ;;
    esac
  done

  command -v kubectl &>/dev/null || { echo "kubectl not found in PATH"; exit 1; }

  if $watch; then
    while true; do analyze; sleep 15; done
  else
    analyze
  fi
}

main "$@"
