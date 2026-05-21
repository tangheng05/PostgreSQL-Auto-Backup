# PostgreSQL Auto Backup

Automatically backs up your PostgreSQL database on a schedule, keeps the last N dumps, and alerts you on Discord, Slack, or email when something goes wrong.

---

## What's included

| File | What it does |
|---|---|
| `backup.conf` | All your settings live here |
| `pg_backup.sh` | The backup script itself |
| `setup_cron.sh` | Set up or remove the automatic schedule |
| `manage_backups.sh` | Browse, restore, or delete backups interactively |

---

## Getting started

**1. Copy the files to your server**

```bash
scp -r . root@your-server:/opt/pg_backup/
```

**2. Open `backup.conf` and set your database details**

```bash
nano /opt/pg_backup/backup.conf
```

The main things to check:

```bash
DB_NAME="serey_prod"                # your database name
BACKUP_DIR="/var/backups/pg_backups" # where dumps are saved
MAX_BACKUPS=7                        # how many to keep before deleting old ones
```

**3. Create the backup directory**

The backup runs as the `postgres` unix user, so the directory needs to be owned by it. Using `/var/backups/pg_backups` is recommended — avoid putting it inside `/root/` since postgres cannot access that path.

```bash
mkdir -p /var/backups/pg_backups
chown postgres:postgres /var/backups/pg_backups
chmod 750 /var/backups/pg_backups
```

**4. Make the scripts executable**

```bash
chmod +x /opt/pg_backup/*.sh
```

**5. Do a dry run to make sure everything looks right**

```bash
sudo bash /opt/pg_backup/pg_backup.sh --dry-run --verbose
```

**6. Run a real backup once to confirm it works**

```bash
sudo bash /opt/pg_backup/pg_backup.sh --verbose
```

**7. Set up the automatic schedule**

```bash
sudo bash /opt/pg_backup/setup_cron.sh
```

Pick a schedule from the menu (default is daily at 2:00 AM). The cron job gets written to `/etc/cron.d/pg_auto_backup` and runs automatically from then on.

---

## All settings in backup.conf

| Setting | Default | Notes |
|---|---|---|
| `DB_NAME` | `serey_prod` | Database to back up |
| `DB_USER` | `postgres` | PostgreSQL user |
| `DB_HOST` | `localhost` | Database host |
| `DB_PORT` | `5432` | Database port |
| `BACKUP_DIR` | `/var/backups/pg_backups` | Where dump files are saved |
| `MAX_BACKUPS` | `7` | Oldest backup deleted when this limit is hit. Set to `0` to keep everything. |
| `VERIFY_BACKUP` | `true` | Checks the dump file is valid after every backup. Deletes it if corrupted. |
| `DUMP_FORMAT` | `custom` | `custom` works with `pg_restore`. Use `plain` for a readable SQL file. |
| `DISCORD_WEBHOOK_URL` | _(empty)_ | Discord alert on success and failure |
| `SLACK_WEBHOOK_URL` | _(empty)_ | Slack alert on success and failure |
| `DISCORD_WEBHOOK_URL` | _(empty)_ | Discord alert on success and failure |
| `TELEGRAM_BOT_TOKEN` | _(empty)_ | Telegram bot token from @BotFather |
| `TELEGRAM_CHAT_ID` | _(empty)_ | Telegram group or channel ID (negative number for groups) |
| `NOTIFY_EMAIL` | _(empty)_ | Email alert — needs `mailutils` installed |
| `LOG_FILE` | `/var/log/pg_backup.log` | Leave empty to only log to stdout |
| `LOG_RETENTION_DAYS` | `30` | Trims log entries older than this |
| `PG_DUMP_EXTRA_OPTS` | _(empty)_ | Any extra flags for `pg_dump`, e.g. `--exclude-table=logs` |

---

## Managing your backups

Run this to get an interactive menu:

```bash
sudo bash /opt/pg_backup/manage_backups.sh
```

From there you can list all backups with their sizes, inspect what's inside a dump file, restore a backup to any database, or delete a specific one.

---

## Restoring manually

If you prefer to do it yourself:

```bash
sudo -u postgres pg_restore \
  -d serey_prod \
  --clean --if-exists \
  /root/db_backups/serey_prod_20260520_020000.dump
```

---

## Notifications

**Telegram** — create a bot via [@BotFather](https://t.me/BotFather) on Telegram, copy the token it gives you, then add the bot to your group. To get the group ID, add [@userinfobot](https://t.me/userinfobot) to the group and it will show the ID (it will be a negative number like `-1001234567890`).

```bash
TELEGRAM_BOT_TOKEN="123456789:AABBccDDeeFFggHH"
TELEGRAM_CHAT_ID="-1001234567890"
```

**Discord** — go to your server, open a channel's settings, then Integrations > Webhooks > New Webhook. Copy the URL and paste it into `backup.conf`:

```bash
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/your-id/your-token"
```

**Slack** — create an incoming webhook in your Slack app settings and paste the URL:

```bash
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/xxx/yyy/zzz"
```

**Email** — install `mailutils` first, then set your address:

```bash
apt install mailutils -y
```

```bash
NOTIFY_EMAIL="you@example.com"
```

You can enable any combination of these at the same time.

---

## Checking logs

```bash
tail -f /var/log/pg_backup.log
```

---

## Removing the cron job

```bash
sudo bash /opt/pg_backup/setup_cron.sh
# choose option 5
```

Or just delete the file directly:

```bash
rm /etc/cron.d/pg_auto_backup
```
