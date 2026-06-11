#!/bin/bash
# Pull-based deploy: fetch the CI-built image from ghcr.io, restart the
# service, verify health, roll back automatically on failure.
#
# Usage: deploy.sh <wess|wess-backend|AutoTLE|all>
#
# Runs inside the webhook container (triggered by GitHub workflow_run
# events) or on the host. Requires the deploy dir mounted/present at the
# same absolute path in both, and the docker socket.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"
COMPOSE_PROJECT="wess-deploy"
LOG_PREFIX="[deploy]"
REPO_NAME="${1:-all}"
HEALTH_TIMEOUT=120

log() { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Notifications (ntfy + email); .env also holds WEBHOOK_SECRET etc.
if [ -f "$DEPLOY_DIR/.env" ]; then
    set -a; source "$DEPLOY_DIR/.env"; set +a
fi
source "$SCRIPT_DIR/lib/notify.sh"

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

image_rev() {
    # short git sha baked into the image by CI (org.opencontainers.image.revision)
    local image="$1"
    local rev
    rev=$(docker image inspect "$image" \
        --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null) || rev=""
    echo "${rev:0:7}"
}

wait_healthy() {
    local container="$1"
    local waited=0
    while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
        local health status
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null) || health=""
        status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null) || status=""

        if [ "$health" = "healthy" ]; then
            return 0
        fi
        # image without a HEALTHCHECK: settle for running after 15s
        if [ -z "$health" ] && [ "$status" = "running" ] && [ "$waited" -ge 15 ]; then
            return 0
        fi
        if [ "$status" = "exited" ] || [ "$status" = "dead" ]; then
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

deploy_service() {
    local repo="$1" service="$2" image="$3"
    local container="${COMPOSE_PROJECT}-${service}-1"

    log "Deploying $repo -> service $service ($image)"

    local old_id old_rev
    old_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null) || old_id=""
    old_rev=$(image_rev "$image")

    if ! compose pull "$service" 2>&1 | tail -2; then
        if [ -n "$old_id" ]; then
            log "Pull failed; registry not reachable or image not published. Keeping running version (${old_rev:-unknown})."
            notify_quiet "WESS deploy skipped: $repo" \
                "Could not pull $image (registry auth/visibility?). Kept running version ${old_rev:-unknown}." \
                "default" "warning"
            return 0
        fi
        log "ERROR: pull failed and no local image exists"
        notify "WESS deploy FAILED: $repo" \
            "Could not pull $image and no local image exists. Service untouched." \
            "urgent" "rotating_light"
        return 1
    fi

    local new_id new_rev
    new_id=$(docker image inspect "$image" --format '{{.Id}}')
    new_rev=$(image_rev "$image")

    if [ "$new_id" = "$old_id" ]; then
        log "Image unchanged (${new_rev:-unknown}); nothing to deploy."
        return 0
    fi

    # keep the outgoing image as :previous for rollback
    if [ -n "$old_id" ]; then
        docker tag "$old_id" "${image%:*}:previous"
    fi

    compose up -d "$service"

    if wait_healthy "$container"; then
        log "$service healthy. ${old_rev:-?} -> ${new_rev:-?}"
        notify_quiet "WESS deployed: $repo" \
            "$service is healthy. ${old_rev:-?} -> ${new_rev:-?}" \
            "default" "rocket"
        return 0
    fi

    log "ERROR: $service failed health check after deploy; rolling back to ${old_rev:-unknown}"
    if [ -n "$old_id" ]; then
        docker tag "$old_id" "$image"
        compose up -d "$service"
        if wait_healthy "$container"; then
            notify "WESS deploy FAILED, rolled back: $repo" \
                "New image (${new_rev:-?}) failed health check. Rolled back to ${old_rev:-?}, service healthy." \
                "urgent" "rotating_light"
        else
            notify "WESS deploy FAILED, rollback ALSO unhealthy: $repo" \
                "New image (${new_rev:-?}) failed health check and rollback to ${old_rev:-?} is not healthy either. Manual intervention needed." \
                "urgent" "rotating_light"
        fi
    else
        notify "WESS deploy FAILED: $repo" \
            "New image (${new_rev:-?}) failed health check and no previous image exists to roll back to." \
            "urgent" "rotating_light"
    fi
    return 1
}

run_tle_sync() {
    local image="ghcr.io/jspwrd/autotle:latest"
    log "Updating AutoTLE image..."
    compose pull auto-tle 2>&1 | tail -1 || log "Pull failed; using local image $(image_rev "$image")"
    log "Running TLE data sync..."
    if compose run --rm auto-tle 2>&1 | tail -5; then
        log "TLE sync complete"
        notify_quiet "WESS TLE sync OK" "AutoTLE sync completed ($(image_rev "$image"))." "min" "satellite"
    else
        log "ERROR: TLE sync failed"
        notify "WESS TLE sync FAILED" "AutoTLE one-shot sync exited non-zero. Check the webhook container logs." "high" "warning"
        return 1
    fi
}

# Serialize deploys (webhook may fire for several repos in quick succession)
exec 200>/tmp/wess-deploy.lock
if ! flock -w 300 200; then
    log "ERROR: could not acquire deploy lock within 5 minutes"
    exit 1
fi

log "Starting deployment (repo: $REPO_NAME)..."
RC=0
case "$REPO_NAME" in
    wess)         deploy_service "wess" "wess-frontend" "ghcr.io/jspwrd/wess:main" || RC=1 ;;
    wess-backend) deploy_service "wess-backend" "wess-backend" "ghcr.io/jspwrd/wess-backend:main" || RC=1 ;;
    AutoTLE)      run_tle_sync || RC=1 ;;
    all)
        deploy_service "wess-backend" "wess-backend" "ghcr.io/jspwrd/wess-backend:main" || RC=1
        deploy_service "wess" "wess-frontend" "ghcr.io/jspwrd/wess:main" || RC=1
        run_tle_sync || RC=1
        ;;
    *)
        log "ERROR: unknown repo '$REPO_NAME' (expected wess|wess-backend|AutoTLE|all)"
        exit 1
        ;;
esac

docker image prune -f > /dev/null 2>&1 || true
log "Deployment finished (rc=$RC)"
exit $RC
