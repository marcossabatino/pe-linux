#!/usr/bin/env bash
# Backup with Retention Policy — compressed backups with checksum, rotation, and restore test
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

BACKUP_DEST="${BACKUP_DEST:-/tmp/backups}"
DAILY_KEEP="${DAILY_KEEP:-7}"
WEEKLY_KEEP="${WEEKLY_KEEP:-4}"
MONTHLY_KEEP="${MONTHLY_KEEP:-6}"
COMPRESS="${COMPRESS:-gzip}"         # gzip|zstd|bzip2
VERIFY="${VERIFY:-true}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
LOG_FILE="${LOG_FILE:-}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] <source_path> [source2 ...]

Options:
  -d, --dest      Backup destination directory (default: ${BACKUP_DEST})
  -n, --name      Backup name prefix (default: basename of source)
  --daily         Daily backups to keep (default: ${DAILY_KEEP})
  --weekly        Weekly backups to keep (default: ${WEEKLY_KEEP})
  --monthly       Monthly backups to keep (default: ${MONTHLY_KEEP})
  --compress      Compression: gzip|zstd|bzip2 (default: ${COMPRESS})
  --no-verify     Skip integrity verification
  --restore       Restore a backup: --restore <archive.tar.gz> --to <path>
  --to            Restore destination path
  --list          List available backups with sizes
  -s, --slack     Slack webhook for notifications
  -l, --log       Log file path
  -h, --help      Show this help

Examples:
  $0 /var/www /etc/nginx --dest /mnt/backups --name webserver
  $0 --list --dest /mnt/backups
  $0 --restore /mnt/backups/webserver-2024-01-15.tar.gz --to /tmp/restore-test
EOF
  exit 0
}

_log() {
  local msg="[$(date '+%F %T')] $*"
  printf "%s\n" "$msg"
  [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE" || true
}

_ok()   { _log "${GREEN}OK:${RESET} $*"; }
_warn() { _log "${YELLOW}WARN:${RESET} $*"; }
_err()  { _log "${RED}ERROR:${RESET} $*" >&2; }

_notify() {
  [[ -z "$SLACK_WEBHOOK" ]] && return
  curl -s -X POST "$SLACK_WEBHOOK" \
    -H 'Content-type: application/json' \
    --data "{\"text\":\"$1\"}" > /dev/null || true
}

compress_ext() {
  case "$COMPRESS" in
    zstd)  echo "tar.zst" ;;
    bzip2) echo "tar.bz2" ;;
    *)     echo "tar.gz"  ;;
  esac
}

compress_flag() {
  case "$COMPRESS" in
    zstd)  echo "--use-compress-program=zstd" ;;
    bzip2) echo "-j" ;;
    *)     echo "-z" ;;
  esac
}

create_backup() {
  local sources=("$@")
  local timestamp; timestamp=$(date '+%Y-%m-%d_%H%M%S')
  local dow; dow=$(date '+%u')   # 1=Mon 7=Sun
  local dom; dom=$(date '+%d')

  local period="daily"
  [[ "$dow" == "7" ]] && period="weekly"
  [[ "$dom" == "01" ]] && period="monthly"

  local archive_name="${BACKUP_NAME}-${period}-${timestamp}.$(compress_ext)"
  local archive_path="${BACKUP_DEST}/${archive_name}"
  local checksum_path="${archive_path}.sha256"

  mkdir -p "$BACKUP_DEST"

  _log "Starting backup"
  _log "  Sources    : ${sources[*]}"
  _log "  Destination: $archive_path"
  _log "  Compression: $COMPRESS"
  _log "  Period     : $period"

  local start; start=$(date +%s)

  tar $(compress_flag) -cf "$archive_path" "${sources[@]}" 2>/dev/null || {
    _err "tar failed for sources: ${sources[*]}"
    _notify ":x: Backup FAILED for ${BACKUP_NAME}"
    exit 1
  }

  local end; end=$(date +%s)
  local duration=$(( end - start ))
  local size; size=$(du -sh "$archive_path" | cut -f1)

  sha256sum "$archive_path" > "$checksum_path"
  _ok "Backup created: $archive_name (${size}, ${duration}s)"

  if $VERIFY; then
    _log "Verifying archive integrity..."
    if sha256sum -c "$checksum_path" --status && \
       tar $(compress_flag) -tf "$archive_path" > /dev/null 2>&1; then
      _ok "Integrity check passed"
    else
      _err "Integrity check FAILED — backup may be corrupt"
      _notify ":x: Backup integrity check FAILED: ${archive_name}"
      exit 1
    fi
  fi

  _notify ":white_check_mark: Backup complete: ${archive_name} (${size})"
  echo "$archive_path"
}

rotate_backups() {
  local prefix="$1" period="$2" keep="$3"
  local files
  mapfile -t files < <(ls -t "${BACKUP_DEST}/${prefix}-${period}-"*.* 2>/dev/null | grep -v '\.sha256$' || true)
  local count="${#files[@]}"

  if [[ $count -gt $keep ]]; then
    local to_delete=$(( count - keep ))
    _log "Rotating ${period}: keeping ${keep}, deleting ${to_delete}"
    for (( i=keep; i<count; i++ )); do
      local f="${files[$i]}"
      rm -f "$f" "${f}.sha256" 2>/dev/null || true
      _log "  Deleted: $(basename "$f")"
    done
  else
    _log "Rotation ${period}: ${count}/${keep} backups (no action needed)"
  fi
}

list_backups() {
  printf "\n${BOLD}Available backups in: %s${RESET}\n\n" "$BACKUP_DEST"
  printf "${BOLD}%-55s %8s  %s${RESET}\n" "ARCHIVE" "SIZE" "DATE"
  printf '%0.s-' {1..85}; echo
  find "$BACKUP_DEST" -name "*.tar.*" ! -name "*.sha256" -printf '%T@ %p\n' 2>/dev/null | \
    sort -rn | while read -r _ file; do
      local size; size=$(du -sh "$file" | cut -f1)
      local date; date=$(stat -c '%y' "$file" | cut -d' ' -f1,2 | cut -d'.' -f1)
      local checksum="${GREEN}✓${RESET}"
      [[ ! -f "${file}.sha256" ]] && checksum="${RED}✗${RESET}"
      printf "%-55s %8s  %s %b\n" "$(basename "$file")" "$size" "$date" "$checksum"
    done
}

restore_backup() {
  local archive="$1" dest="$2"
  [[ ! -f "$archive" ]] && { _err "Archive not found: $archive"; exit 1; }
  [[ -z "$dest"    ]] && { _err "Restore destination (--to) required"; exit 1; }

  local checksum="${archive}.sha256"
  if [[ -f "$checksum" ]]; then
    _log "Verifying checksum before restore..."
    sha256sum -c "$checksum" --status || { _err "Checksum mismatch — aborting restore"; exit 1; }
    _ok "Checksum verified"
  else
    _warn "No checksum file found — skipping verification"
  fi

  mkdir -p "$dest"
  _log "Restoring $(basename "$archive") to $dest ..."
  tar $(compress_flag) -xf "$archive" -C "$dest"
  _ok "Restore complete: $dest"
}

main() {
  local sources=() restore_archive="" restore_dest="" list_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dest)     BACKUP_DEST="$2"; shift 2 ;;
      -n|--name)     BACKUP_NAME="$2"; shift 2 ;;
      --daily)       DAILY_KEEP="$2"; shift 2 ;;
      --weekly)      WEEKLY_KEEP="$2"; shift 2 ;;
      --monthly)     MONTHLY_KEEP="$2"; shift 2 ;;
      --compress)    COMPRESS="$2"; shift 2 ;;
      --no-verify)   VERIFY=false; shift ;;
      --restore)     restore_archive="$2"; shift 2 ;;
      --to)          restore_dest="$2"; shift 2 ;;
      --list)        list_only=true; shift ;;
      -s|--slack)    SLACK_WEBHOOK="$2"; shift 2 ;;
      -l|--log)      LOG_FILE="$2"; shift 2 ;;
      -h|--help)     usage ;;
      *)             sources+=("$1"); shift ;;
    esac
  done

  if $list_only; then
    list_backups; exit 0
  fi

  if [[ -n "$restore_archive" ]]; then
    restore_backup "$restore_archive" "$restore_dest"; exit 0
  fi

  [[ ${#sources[@]} -eq 0 ]] && { _err "No source paths specified"; usage; }

  BACKUP_NAME="${BACKUP_NAME:-$(basename "${sources[0]}")}"

  local archive
  archive=$(create_backup "${sources[@]}")

  rotate_backups "$BACKUP_NAME" "daily"   "$DAILY_KEEP"
  rotate_backups "$BACKUP_NAME" "weekly"  "$WEEKLY_KEEP"
  rotate_backups "$BACKUP_NAME" "monthly" "$MONTHLY_KEEP"

  _log "Done. Archive: $archive"
}

main "$@"
