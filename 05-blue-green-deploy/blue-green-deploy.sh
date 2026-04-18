#!/usr/bin/env bash
# Blue-Green Deployment Helper — orchestrates traffic switching with automatic rollback
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-10}"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-5}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-5}"
ROLLBACK_ON_FAILURE="${ROLLBACK_ON_FAILURE:-true}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DRY_RUN="${DRY_RUN:-false}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] --app <name> --new-version <tag> --health-url <url>

Required:
  -a, --app          Application name
  -v, --new-version  New image tag or version to deploy
  -u, --health-url   Healthcheck URL of the new environment

Options:
  --nginx-config     Path to nginx upstream config file
  --compose-file     Docker Compose file path
  --retries          Healthcheck retries before fail (default: ${HEALTHCHECK_RETRIES})
  --interval         Seconds between healthchecks (default: ${HEALTHCHECK_INTERVAL})
  --no-rollback      Disable automatic rollback on failure
  --dry-run          Print actions without executing
  --slack            Slack webhook URL
  -h, --help         Show this help

Examples:
  $0 --app myapi --new-version v2.1.0 --health-url http://localhost:8081/health
  $0 --app frontend --new-version sha-abc123 --compose-file docker-compose.prod.yml \\
     --health-url http://localhost:3001/health --slack https://hooks.slack.com/...
EOF
  exit 0
}

_log()  { printf "${BOLD}[%s]${RESET} %s\n" "$(date '+%T')" "$*"; }
_ok()   { printf "${GREEN}[%s] OK:${RESET} %s\n" "$(date '+%T')" "$*"; }
_warn() { printf "${YELLOW}[%s] WARN:${RESET} %s\n" "$(date '+%T')" "$*"; }
_err()  { printf "${RED}[%s] ERROR:${RESET} %s\n" "$(date '+%T')" "$*" >&2; }

_run() {
  if $DRY_RUN; then
    printf "${CYAN}[DRY-RUN]${RESET} %s\n" "$*"
  else
    eval "$*"
  fi
}

_notify() {
  local msg="$1"
  [[ -n "$SLACK_WEBHOOK" ]] && curl -s -X POST "$SLACK_WEBHOOK" \
    -H 'Content-type: application/json' \
    --data "{\"text\":\"${msg}\"}" > /dev/null || true
}

detect_current_slot() {
  local app="$1" compose_file="${2:-docker-compose.yml}"
  if command -v docker &>/dev/null && [[ -f "$compose_file" ]]; then
    docker ps --filter "name=${app}-blue" --format '{{.Names}}' 2>/dev/null | \
      grep -q "${app}-blue" && echo "blue" || echo "green"
  else
    echo "blue"
  fi
}

healthcheck() {
  local url="$1" retries="$2" interval="$3" timeout="$4"
  _log "Running healthcheck: $url"
  local attempt=1
  while [[ $attempt -le $retries ]]; do
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
      --max-time "$timeout" "$url" 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^2 ]]; then
      _ok "Healthcheck passed (attempt ${attempt}/${retries}, HTTP ${http_code})"
      return 0
    fi
    _warn "Attempt ${attempt}/${retries} failed (HTTP ${http_code}), retrying in ${interval}s..."
    sleep "$interval"
    (( attempt++ ))
  done
  _err "Healthcheck failed after ${retries} attempts"
  return 1
}

switch_nginx() {
  local config="$1" new_upstream="$2"
  [[ ! -f "$config" ]] && { _err "Nginx config not found: $config"; return 1; }
  _log "Switching nginx upstream to: $new_upstream"
  _run "sed -i 's|server .*:.*;|server ${new_upstream};|g' '${config}'"
  _run "nginx -t"
  _run "nginx -s reload"
  _ok "Nginx reloaded with new upstream"
}

deploy_compose() {
  local compose_file="$1" app="$2" version="$3" slot="$4"
  local service="${app}-${slot}"
  _log "Deploying ${service} version ${version}"
  _run "IMAGE_TAG=${version} docker compose -f '${compose_file}' up -d '${service}'"
  _ok "Container ${service} started"
}

rollback() {
  local app="$1" old_slot="$2" compose_file="${3:-}" nginx_config="${4:-}"
  _warn "Rolling back to slot: ${old_slot}"
  _notify ":warning: *${app}* deployment FAILED — rolling back to ${old_slot}"

  if [[ -n "$nginx_config" ]]; then
    local old_port; old_port=$([[ "$old_slot" == "blue" ]] && echo "8080" || echo "8081")
    switch_nginx "$nginx_config" "127.0.0.1:${old_port}" || true
  fi

  if [[ -n "$compose_file" ]]; then
    local new_slot; new_slot=$([[ "$old_slot" == "blue" ]] && echo "green" || echo "blue")
    _run "docker compose -f '${compose_file}' stop '${app}-${new_slot}'" || true
  fi

  _err "Deployment FAILED. Rolled back to: ${old_slot}"
}

main() {
  local app="" version="" health_url="" nginx_config="" compose_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--app)          app="$2"; shift 2 ;;
      -v|--new-version)  version="$2"; shift 2 ;;
      -u|--health-url)   health_url="$2"; shift 2 ;;
      --nginx-config)    nginx_config="$2"; shift 2 ;;
      --compose-file)    compose_file="$2"; shift 2 ;;
      --retries)         HEALTHCHECK_RETRIES="$2"; shift 2 ;;
      --interval)        HEALTHCHECK_INTERVAL="$2"; shift 2 ;;
      --no-rollback)     ROLLBACK_ON_FAILURE=false; shift ;;
      --dry-run)         DRY_RUN=true; shift ;;
      --slack)           SLACK_WEBHOOK="$2"; shift 2 ;;
      -h|--help)         usage ;;
      *)                 shift ;;
    esac
  done

  [[ -z "$app"        ]] && { _err "Missing --app"; usage; }
  [[ -z "$version"    ]] && { _err "Missing --new-version"; usage; }
  [[ -z "$health_url" ]] && { _err "Missing --health-url"; usage; }

  local current_slot new_slot
  current_slot=$(detect_current_slot "$app" "${compose_file:-docker-compose.yml}")
  new_slot=$([[ "$current_slot" == "blue" ]] && echo "green" || echo "blue")

  printf "\n${BOLD}Blue-Green Deployment${RESET}\n"
  printf "  App      : %s\n" "$app"
  printf "  Version  : %s\n" "$version"
  printf "  Active   : ${CYAN}%s${RESET}\n" "$current_slot"
  printf "  Target   : ${CYAN}%s${RESET}\n" "$new_slot"
  $DRY_RUN && printf "  ${YELLOW}DRY RUN MODE — no changes will be applied${RESET}\n"
  echo ""

  _notify ":rocket: *${app}* deploying v${version} to *${new_slot}* slot"

  if [[ -n "$compose_file" ]]; then
    _log "Step 1/4: Deploy new version to ${new_slot} slot"
    deploy_compose "$compose_file" "$app" "$version" "$new_slot"
    sleep 3
  else
    _log "Step 1/4: Skipped (no compose file — assuming external deployment)"
  fi

  _log "Step 2/4: Health check on new slot"
  if ! healthcheck "$health_url" "$HEALTHCHECK_RETRIES" "$HEALTHCHECK_INTERVAL" "$HEALTHCHECK_TIMEOUT"; then
    if $ROLLBACK_ON_FAILURE; then
      rollback "$app" "$current_slot" "$compose_file" "$nginx_config"
    fi
    exit 1
  fi

  if [[ -n "$nginx_config" ]]; then
    _log "Step 3/4: Switch traffic to ${new_slot}"
    local new_port; new_port=$([[ "$new_slot" == "blue" ]] && echo "8080" || echo "8081")
    if ! switch_nginx "$nginx_config" "127.0.0.1:${new_port}"; then
      $ROLLBACK_ON_FAILURE && rollback "$app" "$current_slot" "$compose_file" "$nginx_config"
      exit 1
    fi
  else
    _log "Step 3/4: Skipped (no nginx config provided)"
  fi

  _log "Step 4/4: Post-switch health check"
  if ! healthcheck "$health_url" 3 3 "$HEALTHCHECK_TIMEOUT"; then
    _warn "Post-switch healthcheck failed — initiating rollback"
    $ROLLBACK_ON_FAILURE && rollback "$app" "$current_slot" "$compose_file" "$nginx_config"
    exit 1
  fi

  if [[ -n "$compose_file" ]]; then
    _log "Stopping old slot: ${current_slot}"
    _run "docker compose -f '${compose_file}' stop '${app}-${current_slot}'" || true
  fi

  printf "\n${GREEN}${BOLD}Deployment successful!${RESET}\n"
  printf "  %s is now serving traffic on slot: ${CYAN}%s${RESET}\n" "$app" "$new_slot"
  _notify ":white_check_mark: *${app}* v${version} deployed successfully on *${new_slot}*"
}

main "$@"
