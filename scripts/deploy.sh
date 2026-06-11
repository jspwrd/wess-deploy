#!/bin/bash
set -euo pipefail

REPOS_DIR="/repos"
COMPOSE_FILE="$REPOS_DIR/wess-deploy/docker-compose.yml"
LOG_PREFIX="[deploy]"
REPO_NAME="${1:-all}"

log() { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') $*"; }

log "Starting deployment (repo: $REPO_NAME)..."

# Determine which repos to pull and which services to rebuild
case "$REPO_NAME" in
    wess)
        REPOS_TO_PULL="wess"
        SERVICES_TO_BUILD="wess-frontend"
        SERVICES_TO_RESTART="wess-frontend"
        ;;
    wess-backend)
        REPOS_TO_PULL="wess-backend"
        SERVICES_TO_BUILD="wess-backend"
        SERVICES_TO_RESTART="wess-backend"
        ;;
    AutoTLE)
        REPOS_TO_PULL="AutoTLE"
        SERVICES_TO_BUILD="auto-tle"
        SERVICES_TO_RESTART=""
        RUN_SYNC=true
        ;;
    *)
        REPOS_TO_PULL="wess wess-backend AutoTLE"
        SERVICES_TO_BUILD="wess-backend wess-frontend auto-tle"
        SERVICES_TO_RESTART="wess-backend wess-frontend"
        RUN_SYNC=true
        ;;
esac

# Pull latest code
for repo in $REPOS_TO_PULL; do
    log "Pulling latest changes for $repo..."
    git -C "$REPOS_DIR/$repo" fetch origin main
    git -C "$REPOS_DIR/$repo" reset --hard origin/main
    log "$repo updated to $(git -C "$REPOS_DIR/$repo" rev-parse --short HEAD)"
done

# Rebuild images
log "Rebuilding images: $SERVICES_TO_BUILD"
docker compose -f "$COMPOSE_FILE" build $SERVICES_TO_BUILD

# Restart long-running services
if [ -n "$SERVICES_TO_RESTART" ]; then
    log "Restarting services: $SERVICES_TO_RESTART"
    docker compose -f "$COMPOSE_FILE" up -d $SERVICES_TO_RESTART
fi

# Run AutoTLE sync if needed
if [ "${RUN_SYNC:-false}" = "true" ]; then
    log "Running AutoTLE data sync..."
    docker compose -f "$COMPOSE_FILE" run --rm auto-tle 2>&1 | tail -5
    log "AutoTLE sync complete"
fi

# Clean up old images
docker image prune -f > /dev/null 2>&1 || true

log "Deployment complete!"
