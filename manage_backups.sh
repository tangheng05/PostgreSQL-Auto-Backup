#!/usr/bin/env bash
# =============================================================================
# manage_backups.sh — List, inspect, and restore PostgreSQL backups
# Usage: ./manage_backups.sh [--config /path/to/backup.conf]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

source "$CONFIG_FILE"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

header() { echo -e "\n${BOLD}$*${RESET}"; }
info()   { echo -e "${CYAN}[INFO]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── List backups ──────────────────────────────────────────────────────────────
list_backups() {
    header "── Available Backups ─────────────────────────────────────"
    local pattern="${BACKUP_DIR}/${BACKUP_PREFIX}_*.${DUMP_EXT}"
    local -a files
    mapfile -t files < <(ls -t $pattern 2>/dev/null || true)

    if [[ ${#files[@]} -eq 0 ]]; then
        warn "No backups found in ${BACKUP_DIR}"
        return 1
    fi

    printf "  %-4s %-30s %8s  %s\n" "No." "Filename" "Size" "Modified"
    printf "  %-4s %-30s %8s  %s\n" "----" "------------------------------" "--------" "-------------------"
    local i=1
    for f in "${files[@]}"; do
        local size mod
        size=$(du -sh "$f" | cut -f1)
        mod=$(stat -c '%y' "$f" 2>/dev/null | cut -c1-19 || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$f" 2>/dev/null)
        printf "  ${GREEN}%-4s${RESET} %-30s %8s  %s\n" "$i" "$(basename "$f")" "$size" "$mod"
        (( i++ ))
    done

    local total
    total=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)
    echo ""
    echo -e "  Total: ${#files[@]} backup(s), ~${total} on disk"
    echo -e "  Max kept: ${MAX_BACKUPS} (set MAX_BACKUPS in backup.conf)"
}

# ── Pick backup by number ─────────────────────────────────────────────────────
pick_backup() {
    local pattern="${BACKUP_DIR}/${BACKUP_PREFIX}_*.${DUMP_EXT}"
    local -a files
    mapfile -t files < <(ls -t $pattern 2>/dev/null || true)

    if [[ ${#files[@]} -eq 0 ]]; then
        error "No backups found."
        exit 1
    fi

    list_backups
    echo ""
    read -rp "$(echo -e "${CYAN}Enter backup number: ${RESET}")" num

    if ! [[ "$num" =~ ^[0-9]+$ ]] || (( num < 1 || num > ${#files[@]} )); then
        error "Invalid selection."
        exit 1
    fi

    PICKED_BACKUP="${files[$((num - 1))]}"
}

# ── Inspect a backup ──────────────────────────────────────────────────────────
inspect_backup() {
    pick_backup
    header "── Backup Info: $(basename "$PICKED_BACKUP") ──"
    pg_restore --list "$PICKED_BACKUP" 2>/dev/null | head -30 || \
        echo "(Cannot list contents — file may not be in custom format)"
}

# ── Restore a backup ──────────────────────────────────────────────────────────
restore_backup() {
    pick_backup

    echo ""
    warn "RESTORE will overwrite data in the target database!"
    read -rp "$(echo -e "${CYAN}Target database name [${DB_NAME}]: ${RESET}")" target_db
    target_db="${target_db:-$DB_NAME}"

    read -rp "$(echo -e "${CYAN}Target DB user [${DB_USER}]: ${RESET}")" target_user
    target_user="${target_user:-$DB_USER}"

    echo ""
    echo -e "  Backup : ${GREEN}$(basename "$PICKED_BACKUP")${RESET}"
    echo -e "  Target : ${RED}${target_db}${RESET} (as ${target_user})"
    echo ""

    read -rp "$(echo -e "${RED}Type 'yes' to confirm restore: ${RESET}")" confirm
    if [[ "$confirm" != "yes" ]]; then
        warn "Restore cancelled."
        exit 0
    fi

    info "Restoring..."
    sudo -u "$target_user" pg_restore \
        -h "$DB_HOST" -p "$DB_PORT" -U "$target_user" \
        -d "$target_db" \
        --clean --if-exists \
        "$PICKED_BACKUP"

    echo -e "${GREEN}Restore complete.${RESET}"
}

# ── Delete a specific backup ──────────────────────────────────────────────────
delete_backup() {
    pick_backup
    echo ""
    read -rp "$(echo -e "${RED}Delete $(basename "$PICKED_BACKUP")? [y/N]: ${RESET}")" ans
    if [[ "${ans,,}" == "y" ]]; then
        rm -f "$PICKED_BACKUP"
        echo -e "${GREEN}Deleted.${RESET}"
    else
        warn "Cancelled."
    fi
}

# ── Main menu ─────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       PostgreSQL Backup Manager                      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    echo "  Database : ${DB_NAME}  |  Backup dir: ${BACKUP_DIR}"
    echo ""
    echo "  1) List all backups"
    echo "  2) Inspect a backup (show contents)"
    echo "  3) Restore a backup"
    echo "  4) Delete a specific backup"
    echo "  5) Exit"
    echo ""
    read -rp "$(echo -e "${CYAN}Choose [1-5]: ${RESET}")" choice

    case "$choice" in
        1) list_backups ;;
        2) inspect_backup ;;
        3) restore_backup ;;
        4) delete_backup ;;
        5) exit 0 ;;
        *) error "Invalid choice."; exit 1 ;;
    esac
}

main
