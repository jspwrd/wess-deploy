#!/bin/bash
# Restore PostgreSQL from a backup file
# Usage: ./restore-db.sh /var/backups/wess-postgres/daily/wess-2026-03-12.sql.gz
set -euo pipefail

COMPOSE_DIR="/home/jsprd/dev/projects/repos/wess-deploy"
LOG_PREFIX="[db-restore]"

log() { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') $*"; }

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <backup-file.sql.gz>"
    echo ""
    echo "Available backups:"
    ls -lh /var/backups/wess-postgres/daily/ 2>/dev/null
    echo ""
    ls -lh /var/backups/wess-postgres/weekly/ 2>/dev/null
    exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
    log "ERROR: File not found: $BACKUP_FILE"
    exit 1
fi

log "WARNING: This will overwrite the current database!"
read -p "Are you sure? (type 'yes' to confirm): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    log "Aborted."
    exit 0
fi

log "Restoring from: $BACKUP_FILE"
gunzip -c "$BACKUP_FILE" | sudo docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T postgres \
    psql -U wess -d wess

log "Restore complete. Restarting backend to reconnect..."
sudo docker compose -f "$COMPOSE_DIR/docker-compose.yml" restart wess-backend

log "Done!"
