#!/usr/bin/env bash
# =============================================================================
# pg_backup.sh — Smart PostgreSQL Auto Backup Script
# Usage: ./pg_backup.sh [--config /path/to/backup.conf] [--dry-run] [--verbose]
# =============================================================================

set -euo pipefail

# ── Defaults (overridden by backup.conf) ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
DRY_RUN=false
VERBOSE=false

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)   CONFIG_FILE="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --verbose)  VERBOSE=true; shift ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Load config ───────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi
# shellcheck source=backup.conf
source "$CONFIG_FILE"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

info()    { log "INFO " "$@"; }
success() { log "OK   " "$@"; }
warn()    { log "WARN " "$@"; }
error()   { log "ERROR" "$@" >&2; }
verbose() { $VERBOSE && log "DEBUG" "$@" || true; }

# ── Notifications ─────────────────────────────────────────────────────────────
# notify "OK"|"FAIL" "short message" ["filename" "size" "elapsed" "total_count" "total_size"]
notify() {
    local status="$1"
    local message="$2"
    local filename="${3:-}"
    local size="${4:-}"
    local elapsed="${5:-}"
    local total_count="${6:-}"
    local total_size="${7:-}"

    # Build a file list of all current backups for the notification
    local file_list=""
    if [[ -n "$filename" ]]; then
        local i=1
        while IFS= read -r f; do
            local f_size f_date
            f_size=$(du -sh "$f" 2>/dev/null | cut -f1)
            f_date=$(stat -c '%y' "$f" 2>/dev/null | cut -c1-16)
            # Mark the newest backup
            if [[ "$(basename "$f")" == "$filename" ]]; then
                file_list+="  [new] $(basename "$f") — ${f_size} (${f_date})\n"
            else
                file_list+="  [${i}] $(basename "$f") — ${f_size} (${f_date})\n"
            fi
            (( i++ ))
        done < <(ls -t "${BACKUP_DIR}/${BACKUP_PREFIX}_"*.${DUMP_EXT} 2>/dev/null)
    fi

    if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
        local icon=":white_check_mark:"
        [[ "$status" == "FAIL" ]] && icon=":x:"
        local text="${icon} *PG Backup ${status}* on \`$(hostname)\`\n${message}"
        if [[ -n "$filename" ]]; then
            text+="\n\n*New backup:* \`${filename}\`  |  *Size:* ${size}  |  *Time:* ${elapsed}s"
            text+="\n*Stored backups (${total_count}/${MAX_BACKUPS}):*\n\`\`\`${file_list}\`\`\`"
        fi
        curl -s -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-type: application/json' \
            --data "{\"text\":\"${text}\"}" \
            >/dev/null 2>&1 || warn "Slack notification failed"
    fi

    if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
        local color=3066993
        [[ "$status" == "FAIL" ]] && color=15158332

        local fields=""
        if [[ -n "$filename" ]]; then
            fields+=$(printf '{"name":"File","value":"`%s`","inline":false},' "$filename")
            fields+=$(printf '{"name":"Size","value":"%s","inline":true},' "$size")
            fields+=$(printf '{"name":"Duration","value":"%ss","inline":true},' "$elapsed")
            fields+=$(printf '{"name":"Stored","value":"%s / %s total","inline":true},' "$total_count" "$MAX_BACKUPS")
            fields+=$(printf '{"name":"Total on disk","value":"%s","inline":true},' "$total_size")
            if [[ -n "$file_list" ]]; then
                local escaped_list
                escaped_list=$(printf '%s' "$file_list" | sed 's/"/\\"/g' | tr '\n' '\n' | sed ':a;N;$!ba;s/\n/\\n/g')
                fields+=$(printf '{"name":"All backups","value":"```%s```","inline":false},' "$escaped_list")
            fi
            # Remove trailing comma
            fields="${fields%,}"
        fi

        local payload
        if [[ -n "$fields" ]]; then
            payload=$(printf '{"embeds":[{"title":"PG Backup %s","description":"%s","color":%d,"fields":[%s],"footer":{"text":"%s • %s"}}]}' \
                "$status" "$message" "$color" "$fields" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')")
        else
            payload=$(printf '{"embeds":[{"title":"PG Backup %s","description":"%s","color":%d,"footer":{"text":"%s • %s"}}]}' \
                "$status" "$message" "$color" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')")
        fi

        curl -s -X POST "$DISCORD_WEBHOOK_URL" \
            -H 'Content-type: application/json' \
            --data "$payload" \
            >/dev/null 2>&1 || warn "Discord notification failed"
    fi

    if [[ -n "${NOTIFY_EMAIL:-}" ]] && command -v mail &>/dev/null; then
        echo "$message" | mail -s "[PG Backup] $status - $(hostname)" "$NOTIFY_EMAIL" \
            >/dev/null 2>&1 || warn "Email notification failed"
    fi
}

# ── Lock file (prevent overlapping runs) ──────────────────────────────────────
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
        if kill -0 "$pid" 2>/dev/null; then
            error "Backup already running (PID $pid). Exiting."
            exit 1
        else
            warn "Stale lock file found (PID $pid no longer running). Removing."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo "$$" > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# ── Cleanup on exit ───────────────────────────────────────────────────────────
BACKUP_FILEPATH=""
cleanup_on_failure() {
    local exit_code=$?
    release_lock
    if [[ $exit_code -ne 0 ]]; then
        error "Backup FAILED (exit $exit_code)"
        if [[ -n "$BACKUP_FILEPATH" && -f "$BACKUP_FILEPATH" ]]; then
            warn "Removing incomplete backup: $BACKUP_FILEPATH"
            rm -f "$BACKUP_FILEPATH"
        fi
        notify "FAIL" "Backup of '${DB_NAME}' on $(hostname) failed. Check ${LOG_FILE:-stdout}." "" "" "" "" ""
    fi
}
trap cleanup_on_failure EXIT

# ── Rotate old backups ────────────────────────────────────────────────────────
rotate_backups() {
    if [[ "${MAX_BACKUPS:-0}" -le 0 ]]; then
        verbose "Retention disabled (MAX_BACKUPS=0), skipping rotation."
        return
    fi

    local pattern="${BACKUP_DIR}/${BACKUP_PREFIX}_*.${DUMP_EXT}"
    local -a backups
    # Sort by modification time, oldest first
    mapfile -t backups < <(ls -t $pattern 2>/dev/null | tail -n +$(( MAX_BACKUPS + 1 )))

    if [[ ${#backups[@]} -eq 0 ]]; then
        verbose "No old backups to rotate."
        return
    fi

    for old in "${backups[@]}"; do
        if $DRY_RUN; then
            info "[DRY RUN] Would delete old backup: $old"
        else
            info "Deleting old backup: $(basename "$old")"
            rm -f "$old"
        fi
    done
}

# ── Rotate logs ───────────────────────────────────────────────────────────────
rotate_logs() {
    if [[ -z "${LOG_FILE:-}" || "${LOG_RETENTION_DAYS:-0}" -le 0 || ! -f "$LOG_FILE" ]]; then
        return
    fi
    local tmp_log="${LOG_FILE}.tmp"
    local cutoff
    cutoff=$(date -d "${LOG_RETENTION_DAYS} days ago" '+%Y-%m-%d' 2>/dev/null || \
             date -v "-${LOG_RETENTION_DAYS}d" '+%Y-%m-%d' 2>/dev/null || echo "")
    if [[ -n "$cutoff" ]]; then
        grep -v "^\[$(echo "$cutoff" | sed 's/-/\\-/g')" "$LOG_FILE" > "$tmp_log" 2>/dev/null || true
        mv "$tmp_log" "$LOG_FILE"
        verbose "Log entries older than ${LOG_RETENTION_DAYS} days removed."
    fi
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
preflight_checks() {
    local ok=true

    if ! command -v pg_dump &>/dev/null; then
        error "pg_dump not found. Install postgresql-client."
        ok=false
    fi

    if [[ ! -d "$BACKUP_DIR" ]]; then
        info "Backup directory does not exist, creating: $BACKUP_DIR"
        if ! $DRY_RUN; then
            mkdir -p "$BACKUP_DIR"
            chmod 750 "$BACKUP_DIR"
        fi
    fi

    if [[ ! -w "$BACKUP_DIR" ]]; then
        error "Backup directory is not writable: $BACKUP_DIR"
        ok=false
    fi

    # Test DB connectivity via Unix socket (peer auth — no password needed)
    if ! sudo -u "$DB_USER" psql -d "$DB_NAME" -c "SELECT 1;" &>/dev/null; then
        error "Cannot connect to database '${DB_NAME}' as unix user '${DB_USER}'."
        ok=false
    fi

    $ok || exit 1
}

# ── Main backup ───────────────────────────────────────────────────────────────
run_backup() {
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    BACKUP_FILEPATH="${BACKUP_DIR}/${BACKUP_PREFIX}_${timestamp}.${DUMP_EXT}"

    info "Starting backup: DB='${DB_NAME}' → $(basename "$BACKUP_FILEPATH")"

    if $DRY_RUN; then
        info "[DRY RUN] Would run: pg_dump -Fc ${DB_NAME} -f ${BACKUP_FILEPATH}"
        return
    fi

    local start_time=$SECONDS
    sudo -u "$DB_USER" pg_dump \
        -F "${DUMP_FORMAT:0:1}" \
        ${PG_DUMP_EXTRA_OPTS:-} \
        "$DB_NAME" \
        -f "$BACKUP_FILEPATH"

    local elapsed=$(( SECONDS - start_time ))
    local size
    size=$(du -sh "$BACKUP_FILEPATH" | cut -f1)

    success "Backup complete: $(basename "$BACKUP_FILEPATH") | Size: ${size} | Time: ${elapsed}s"

    # Verify the dump file is valid (not silently corrupted)
    if [[ "${VERIFY_BACKUP:-true}" == "true" ]]; then
        info "Verifying backup integrity..."
        if pg_restore --list "$BACKUP_FILEPATH" &>/dev/null; then
            success "Verification passed — backup file is valid."
        else
            error "Verification FAILED — backup file appears corrupted: $BACKUP_FILEPATH"
            rm -f "$BACKUP_FILEPATH"
            exit 1
        fi
    fi

    local total_count total_size
    total_count=$(ls "${BACKUP_DIR}/${BACKUP_PREFIX}_"*.${DUMP_EXT} 2>/dev/null | wc -l)
    total_size=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)

    notify "OK" "Backup of \`${DB_NAME}\` completed successfully." \
        "$(basename "$BACKUP_FILEPATH")" "$size" "$elapsed" "$total_count" "$total_size"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    local count size_total
    count=$(ls "${BACKUP_DIR}/${BACKUP_PREFIX}_"*.${DUMP_EXT} 2>/dev/null | wc -l)
    size_total=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)
    info "Backups in ${BACKUP_DIR}: ${count} file(s), total ~${size_total}"
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
    info "=== PostgreSQL Backup Started (PID $$) ==="
    $DRY_RUN && warn "DRY RUN mode — no changes will be made."

    acquire_lock
    rotate_logs
    preflight_checks
    run_backup
    rotate_backups
    print_summary
    release_lock

    info "=== Backup Finished Successfully ==="
    # Clear the trap so cleanup_on_failure doesn't fire on clean exit
    trap - EXIT
}

main
