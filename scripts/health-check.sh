#!/bin/bash
# Health check script - monitors all wess services
# Runs every 5 minutes via cron, logs failures, and writes status file
# Sends notifications via email (Fastmail SMTP) and ntfy.sh on failure/recovery
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="/var/log/wess"
STATUS_FILE="$STATE_DIR/health-status"
PREV_STATUS_FILE="$STATE_DIR/health-prev"
LOG_PREFIX="[health-check]"
FAILURES=0
DETAILS=""

mkdir -p "$STATE_DIR" 2>/dev/null || true

# Load notification config from .env
if [ -f "$COMPOSE_DIR/.env" ]; then
    set -a
    source "$COMPOSE_DIR/.env"
    set +a
fi
source "$SCRIPT_DIR/lib/notify.sh"

log() { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# --- Check functions ---
check_service() {
    local name="$1"
    local url="$2"
    local expected_code="${3:-200}"
    local timeout="${4:-10}"

    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "$expected_code" ]; then
        DETAILS="$DETAILS  ✓ $name (HTTP $HTTP_CODE)\n"
        return 0
    else
        DETAILS="$DETAILS  ✗ $name (HTTP $HTTP_CODE, expected $expected_code)\n"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
}

check_container() {
    local name="$1"
    local status
    status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "not_found")

    if [ "$status" = "running" ]; then
        DETAILS="$DETAILS  ✓ $name container ($status)\n"
        return 0
    else
        DETAILS="$DETAILS  ✗ $name container ($status)\n"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
}

# --- Run checks ---

# Check containers
check_container "wess-deploy-nginx-1"
check_container "wess-deploy-wess-frontend-1"
check_container "wess-deploy-wess-backend-1"
check_container "wess-deploy-postgres-1"
check_container "wess-deploy-webhook-1"

# Check HTTP endpoints
check_service "Backend Health" "http://localhost:80/health"
check_service "Backend DB Health" "http://localhost:80/health/db"
check_service "Frontend" "http://localhost:80/" 200
check_service "API" "http://localhost:80/api/v1/tles-complete?limit=1"
check_service "Webhook listener" "http://localhost:80/webhook"

# Check disk space (alert if >85% used)
DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
if [ "$DISK_USAGE" -gt 85 ]; then
    DETAILS="$DETAILS  ✗ Disk usage: ${DISK_USAGE}% (threshold: 85%)\n"
    FAILURES=$((FAILURES + 1))
else
    DETAILS="$DETAILS  ✓ Disk usage: ${DISK_USAGE}%\n"
fi

# Check database connectivity
if docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T postgres pg_isready -U wess -d wess >/dev/null 2>&1; then
    DETAILS="$DETAILS  ✓ PostgreSQL accepting connections\n"
else
    DETAILS="$DETAILS  ✗ PostgreSQL not responding\n"
    FAILURES=$((FAILURES + 1))
fi

# Check TLE data freshness (alert if no update in 48h; sync runs daily)
TLE_AGE_HOURS=$(docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T postgres \
    psql -U wess -d wess -tAc \
    "SELECT COALESCE(EXTRACT(EPOCH FROM (now() - max(updated_at)))/3600, 9999)::int FROM tles;" 2>/dev/null || echo "9999")
if [ "$TLE_AGE_HOURS" -gt 48 ]; then
    DETAILS="$DETAILS  ✗ TLE data stale: last update ${TLE_AGE_HOURS}h ago (threshold: 48h)\n"
    FAILURES=$((FAILURES + 1))
else
    DETAILS="$DETAILS  ✓ TLE data fresh (${TLE_AGE_HOURS}h old)\n"
fi

# --- Determine status and handle notifications ---
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
PREV_STATE=$(cat "$PREV_STATUS_FILE" 2>/dev/null || echo "UNKNOWN")
PLAIN_DETAILS=$(echo -e "$DETAILS" | sed 's/\\n/\n/g')

if [ "$FAILURES" -eq 0 ]; then
    STATUS="HEALTHY"

    # Send recovery notification if previous state was degraded
    if [ "$PREV_STATE" = "DEGRADED" ]; then
        log "RECOVERED: All checks passing again"
        echo -e "$DETAILS"
        notify \
            "✅ WESS Recovered" \
            "All services are healthy again.

$PLAIN_DETAILS
Recovered at: $TIMESTAMP" \
            "default" \
            "white_check_mark"
    else
        # Only log healthy status once per hour
        MINUTE=$(date '+%M')
        if [ "$((MINUTE % 60))" -lt 5 ]; then
            log "All checks passed"
            echo -e "$DETAILS" | sed 's/^/  /'
        fi
    fi
else
    STATUS="DEGRADED"
    log "WARNING: $FAILURES check(s) failed!"
    echo -e "$DETAILS"

    # Only notify on state transition (healthy → degraded) to avoid spam
    if [ "$PREV_STATE" != "DEGRADED" ]; then
        notify \
            "🚨 WESS Alert: $FAILURES check(s) failed" \
            "Health check detected failures:

$PLAIN_DETAILS
Time: $TIMESTAMP
Host: $(hostname)" \
            "urgent" \
            "rotating_light"
    fi

    # Auto-recovery: try to restart failed containers
    for container in wess-deploy-nginx-1 wess-deploy-wess-frontend-1 wess-deploy-wess-backend-1 wess-deploy-postgres-1 wess-deploy-webhook-1; do
        CSTATUS=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
        if [ "$CSTATUS" != "running" ] && [ "$CSTATUS" != "not_found" ]; then
            log "Attempting to restart $container..."
            docker start "$container" 2>/dev/null || true
        fi
    done
fi

# Save current state for next run's comparison
echo "$STATUS" > "$PREV_STATUS_FILE"

# Write full status file (can be read by external monitors)
echo "$TIMESTAMP | $STATUS" > "$STATUS_FILE"
echo -e "$DETAILS" >> "$STATUS_FILE"
