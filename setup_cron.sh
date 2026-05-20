#!/usr/bin/env bash
# =============================================================================
# setup_cron.sh — Interactive cron job installer for pg_backup.sh
# Usage: sudo ./setup_cron.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/pg_backup.sh"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
CRON_TAG="# pg_backup_auto"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}$*${RESET}"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo ./setup_cron.sh)"
        exit 1
    fi
}

confirm() {
    local prompt="${1:-Continue?}"
    read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${RESET}")" ans
    [[ "${ans,,}" == "y" ]]
}

pick_schedule() {
    header "── Backup Schedule ──────────────────────────────────────"
    echo "  1) Every 6 hours"
    echo "  2) Every 12 hours"
    echo "  3) Daily at a specific time"
    echo "  4) Weekly on a specific day & time"
    echo "  5) Custom cron expression"
    echo ""
    read -rp "$(echo -e "${CYAN}Choose [1-5]: ${RESET}")" choice

    case "$choice" in
        1) CRON_SCHEDULE="0 */6 * * *";  CRON_DESC="every 6 hours" ;;
        2) CRON_SCHEDULE="0 */12 * * *"; CRON_DESC="every 12 hours" ;;
        3)
            read -rp "$(echo -e "${CYAN}Hour (0-23): ${RESET}")" hour
            read -rp "$(echo -e "${CYAN}Minute (0-59, default 0): ${RESET}")" minute
            minute="${minute:-0}"
            CRON_SCHEDULE="${minute} ${hour} * * *"
            CRON_DESC="daily at $(printf '%02d:%02d' "$hour" "$minute")"
            ;;
        4)
            echo "  Days: 0=Sun 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri 6=Sat"
            read -rp "$(echo -e "${CYAN}Day of week [0-6]: ${RESET}")" dow
            read -rp "$(echo -e "${CYAN}Hour (0-23): ${RESET}")" hour
            read -rp "$(echo -e "${CYAN}Minute (0-59, default 0): ${RESET}")" minute
            minute="${minute:-0}"
            CRON_SCHEDULE="${minute} ${hour} * * ${dow}"
            CRON_DESC="weekly (day ${dow}) at $(printf '%02d:%02d' "$hour" "$minute")"
            ;;
        5)
            echo "  Format: minute hour day month weekday"
            echo "  Example: 30 2 * * *  (every day at 02:30)"
            read -rp "$(echo -e "${CYAN}Cron expression: ${RESET}")" CRON_SCHEDULE
            CRON_DESC="custom: ${CRON_SCHEDULE}"
            ;;
        *)
            error "Invalid choice."
            exit 1
            ;;
    esac
}

pick_retention() {
    header "── Retention Policy ─────────────────────────────────────"
    read -rp "$(echo -e "${CYAN}Max number of backups to keep (current in backup.conf — press Enter to keep): ${RESET}")" new_max

    if [[ -n "$new_max" && "$new_max" =~ ^[0-9]+$ ]]; then
        # Update backup.conf in-place
        sed -i "s/^MAX_BACKUPS=.*/MAX_BACKUPS=${new_max}/" "$CONFIG_FILE"
        success "MAX_BACKUPS set to ${new_max} in backup.conf"
    else
        local current
        current=$(grep '^MAX_BACKUPS=' "$CONFIG_FILE" | cut -d= -f2)
        info "Keeping existing MAX_BACKUPS=${current}"
    fi
}

install_cron() {
    local cron_user="${1:-root}"
    local cron_line="${CRON_SCHEDULE} ${cron_user} bash ${BACKUP_SCRIPT} --config ${CONFIG_FILE} ${CRON_TAG}"

    # Write to /etc/cron.d/ so it survives user crontab edits
    local cron_file="/etc/cron.d/pg_auto_backup"

    header "── Installing Cron Job ───────────────────────────────────"
    echo -e "  Schedule : ${GREEN}${CRON_DESC}${RESET}"
    echo -e "  Cron file: ${GREEN}${cron_file}${RESET}"
    echo -e "  Command  : bash ${BACKUP_SCRIPT}"
    echo ""

    if ! confirm "Install this cron job?"; then
        warn "Aborted."
        exit 0
    fi

    cat > "$cron_file" <<EOF
# Managed by setup_cron.sh — edit backup.conf to change settings
# To remove: sudo rm ${cron_file}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${CRON_SCHEDULE} ${cron_user} bash ${BACKUP_SCRIPT} --config ${CONFIG_FILE} ${CRON_TAG}
EOF

    chmod 644 "$cron_file"
    success "Cron job installed at ${cron_file}"
}

show_status() {
    header "── Current Status ────────────────────────────────────────"
    local cron_file="/etc/cron.d/pg_auto_backup"

    if [[ -f "$cron_file" ]]; then
        success "Cron job is ACTIVE:"
        grep -v '^#' "$cron_file" | grep -v '^$' || true
    else
        warn "No cron job installed yet."
    fi

    echo ""
    if [[ -f "${CONFIG_FILE}" ]]; then
        info "Active config: ${CONFIG_FILE}"
        grep -E '^(DB_NAME|BACKUP_DIR|MAX_BACKUPS|DUMP_FORMAT)=' "$CONFIG_FILE" | \
            while IFS='=' read -r k v; do
                echo "  ${k} = ${v}"
            done
    fi
}

uninstall_cron() {
    local cron_file="/etc/cron.d/pg_auto_backup"
    if [[ -f "$cron_file" ]]; then
        if confirm "Remove cron job at ${cron_file}?"; then
            rm -f "$cron_file"
            success "Cron job removed."
        fi
    else
        warn "No cron job found to remove."
    fi
}

# ── Main menu ─────────────────────────────────────────────────────────────────
main() {
    require_root

    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       PostgreSQL Auto Backup — Cron Setup            ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    # Make backup script executable
    chmod +x "$BACKUP_SCRIPT"

    echo "  1) Install / update cron job"
    echo "  2) Show current status"
    echo "  3) Run backup now (test)"
    echo "  4) Run backup now (dry-run)"
    echo "  5) Uninstall cron job"
    echo "  6) Exit"
    echo ""
    read -rp "$(echo -e "${CYAN}Choose [1-6]: ${RESET}")" main_choice

    case "$main_choice" in
        1)
            pick_schedule
            pick_retention
            read -rp "$(echo -e "${CYAN}Run backup as which user? [root]: ${RESET}")" run_user
            run_user="${run_user:-root}"
            install_cron "$run_user"
            ;;
        2) show_status ;;
        3)
            info "Running backup now..."
            bash "$BACKUP_SCRIPT" --config "$CONFIG_FILE" --verbose
            ;;
        4)
            info "Running dry-run..."
            bash "$BACKUP_SCRIPT" --config "$CONFIG_FILE" --dry-run --verbose
            ;;
        5) uninstall_cron ;;
        6) exit 0 ;;
        *) error "Invalid choice."; exit 1 ;;
    esac
}

main
