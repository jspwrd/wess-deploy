#!/bin/bash
# Daily PostgreSQL backup with rotation
# Keeps: 7 daily backups + 4 weekly backups (Sundays)
set -euo pipefail

BACKUP_DIR="/var/backups/wess-postgres"
COMPOSE_DIR="/home/jsprd/dev/projects/repos/wess-deploy"
LOG_PREFIX="[db-backup]"
DATE=$(date '+%Y-%m-%d')
DAY_OF_WEEK=$(date '+%u')  # 1=Monday, 7=Sunday

log() { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR/daily" "$BACKUP_DIR/weekly"

# --- Daily backup ---
DAILY_FILE="$BACKUP_DIR/daily/wess-${DATE}.sql.gz"
log "Starting daily backup..."

sudo docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T postgres \
    pg_dump -U wess -d wess --clean --if-exists | gzip > "$DAILY_FILE"

if [ -s "$DAILY_FILE" ]; then
    SIZE=$(du -h "$DAILY_FILE" | cut -f1)
    log "Daily backup complete: $DAILY_FILE ($SIZE)"
else
    log "ERROR: Backup file is empty, something went wrong"
    rm -f "$DAILY_FILE"
    exit 1
fi

# --- Weekly backup (copy Sunday's daily to weekly) ---
if [ "$DAY_OF_WEEK" -eq 7 ]; then
    WEEKLY_FILE="$BACKUP_DIR/weekly/wess-${DATE}.sql.gz"
    cp "$DAILY_FILE" "$WEEKLY_FILE"
    log "Weekly backup saved: $WEEKLY_FILE"
fi

# --- Rotation: keep 7 daily, 4 weekly ---
log "Rotating old backups..."

# Delete daily backups older than 7 days
find "$BACKUP_DIR/daily" -name "*.sql.gz" -mtime +7 -delete 2>/dev/null || true
DAILY_COUNT=$(find "$BACKUP_DIR/daily" -name "*.sql.gz" | wc -l)

# Delete weekly backups older than 28 days
find "$BACKUP_DIR/weekly" -name "*.sql.gz" -mtime +28 -delete 2>/dev/null || true
WEEKLY_COUNT=$(find "$BACKUP_DIR/weekly" -name "*.sql.gz" | wc -l)

log "Rotation complete. $DAILY_COUNT daily, $WEEKLY_COUNT weekly backups retained."

# --- Total backup size ---
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
log "Total backup storage: $TOTAL_SIZE"
