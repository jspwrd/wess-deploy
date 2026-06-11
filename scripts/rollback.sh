#!/bin/bash
# Roll a service back to the previously deployed image (tagged :previous
# by deploy.sh). Usage: rollback.sh <wess|wess-backend>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"
LOG_PREFIX="[rollback]"

log() { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') $*"; }

if [ -f "$DEPLOY_DIR/.env" ]; then
    set -a; source "$DEPLOY_DIR/.env"; set +a
fi
source "$SCRIPT_DIR/lib/notify.sh"

case "${1:-}" in
    wess)         SERVICE="wess-frontend"; IMAGE="ghcr.io/jspwrd/wess" ;;
    wess-backend) SERVICE="wess-backend";  IMAGE="ghcr.io/jspwrd/wess-backend" ;;
    *) echo "Usage: $0 <wess|wess-backend>"; exit 1 ;;
esac

if ! docker image inspect "$IMAGE:previous" >/dev/null 2>&1; then
    log "ERROR: no $IMAGE:previous image exists — nothing recorded to roll back to"
    exit 1
fi

PREV_REV=$(docker image inspect "$IMAGE:previous" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null | cut -c1-7)

log "Rolling $SERVICE back to ${PREV_REV:-unknown}..."
docker tag "$IMAGE:previous" "$IMAGE:main"
docker compose -f "$COMPOSE_FILE" up -d "$SERVICE"

log "Done. NOTE: the next successful deploy will overwrite :main again."
notify_quiet "WESS manual rollback: $SERVICE" \
    "Rolled back to ${PREV_REV:-unknown}. Next deploy will move forward again." \
    "high" "rewind"
