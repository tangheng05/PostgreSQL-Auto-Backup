# PostgreSQL Auto Backup System

Smart, configurable PostgreSQL backup with automatic rotation and cron scheduling.

## Files

| File | Purpose |
|---|---|
| `backup.conf` | All settings — edit this first |
| `pg_backup.sh` | Main backup script (run manually or via cron) |
| `setup_cron.sh` | Interactive cron installer / manager |
| `manage_backups.sh` | List, inspect, restore, or delete backups |

---

## Quick Start

### 1. Upload to your server

```bash
scp -r . root@your-server:/opt/pg_backup/
```

### 2. Edit config

```bash
nano /opt/pg_backup/backup.conf
```

Key settings:
```bash
DB_NAME="serey_prod"        # your database
BACKUP_DIR="/root/db_backups"
MAX_BACKUPS=5               # keep last 5, auto-delete older ones
```

### 3. Make scripts executable

```bash
chmod +x /opt/pg_backup/*.sh
```

### 4. Test a dry run

```bash
sudo bash /opt/pg_backup/pg_backup.sh --dry-run --verbose
```

### 5. Run a real backup once to confirm it works

```bash
sudo bash /opt/pg_backup/pg_backup.sh --verbose
```

### 6. Set up automatic cron job

```bash
sudo bash /opt/pg_backup/setup_cron.sh
```

Follow the interactive prompts to pick your schedule and retention policy.
The cron job is written to `/etc/cron.d/pg_auto_backup`.

---

## Customization (backup.conf)

| Setting | Default | Description |
|---|---|---|
| `DB_NAME` | `serey_prod` | Database to back up |
| `DB_USER` | `postgres` | PostgreSQL user |
| `BACKUP_DIR` | `/root/db_backups` | Where `.dump` files are stored |
| `MAX_BACKUPS` | `5` | Oldest backups deleted when limit exceeded. `0` = keep all |
| `DUMP_FORMAT` | `custom` | `custom` (pg_restore), `plain` (SQL text), `tar` |
| `SLACK_WEBHOOK_URL` | _(empty)_ | Slack notification on success/failure |
| `NOTIFY_EMAIL` | _(empty)_ | Email notification (requires `mail`) |
| `LOG_FILE` | `/var/log/pg_backup.log` | Log path. Empty = no log file |
| `LOG_RETENTION_DAYS` | `30` | Days of logs to keep |
| `PG_DUMP_EXTRA_OPTS` | _(empty)_ | Extra flags e.g. `--exclude-table=logs` |

---

## Managing Backups

```bash
sudo bash /opt/pg_backup/manage_backups.sh
```

Options:
- **List** — see all backups with size and date
- **Inspect** — view table of contents inside a `.dump` file
- **Restore** — restore any backup to any database (with confirmation)
- **Delete** — manually remove a specific backup

---

## Managing the Cron Job

```bash
# View current schedule
cat /etc/cron.d/pg_auto_backup

# Edit schedule manually
nano /etc/cron.d/pg_auto_backup

# Remove the cron job
sudo bash /opt/pg_backup/setup_cron.sh   # choose option 5

# View logs
tail -f /var/log/pg_backup.log
```

---

## Restore a Backup Manually

```bash
# Using manage_backups.sh (recommended)
sudo bash /opt/pg_backup/manage_backups.sh

# Or manually
sudo -u postgres pg_restore \
  -d serey_prod \
  --clean --if-exists \
  /root/db_backups/serey_prod_20260520_020300.dump
```

---

## Notifications

**Slack:** Set `SLACK_WEBHOOK_URL` in `backup.conf` with your incoming webhook URL.

**Email:** Set `NOTIFY_EMAIL` and ensure `mailutils` is installed:
```bash
apt install mailutils -y
```
