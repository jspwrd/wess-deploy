#!/bin/bash
# Health check script - monitors all wess services
# Runs every 5 minutes via cron, logs failures, and writes status file
# Sends notifications via email (Fastmail SMTP) and ntfy.sh on failure/recovery
set -uo pipefail

COMPOSE_DIR="/home/jsprd/dev/projects/repos/wess-deploy"
STATUS_FILE="/var/log/wess-health-status"
PREV_STATUS_FILE="/var/log/wess-health-prev"
LOG_PREFIX="[health-check]"
FAILURES=0
DETAILS=""

# Load notification config from .env
if [ -f "$COMPOSE_DIR/.env" ]; then
    set -a
    source "$COMPOSE_DIR/.env"
    set +a
fi

log() { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# --- Notification functions ---
send_ntfy() {
    local title="$1"
    local message="$2"
    local priority="${3:-high}"
    local tags="${4:-warning}"

    if [ -n "${NTFY_TOPIC:-}" ]; then
        curl -sf -o /dev/null \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -H "Tags: $tags" \
            -d "$message" \
            "https://ntfy.sh/$NTFY_TOPIC" 2>/dev/null || log "WARNING: ntfy notification failed"
    fi
}

send_email() {
    local subject="$1"
    local body="$2"

    if [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_USER:-}" ] && [ -n "${SMTP_PASS:-}" ]; then
        local recipients="${ALERT_EMAILS:-$SMTP_USER}"
        local rcpt_args=""
        local to_header=""

        # Build --mail-rcpt flags and To: header for each recipient
        IFS=',' read -ra ADDRS <<< "$recipients"
        for addr in "${ADDRS[@]}"; do
            addr=$(echo "$addr" | xargs)  # trim whitespace
            rcpt_args="$rcpt_args --mail-rcpt $addr"
            [ -n "$to_header" ] && to_header="$to_header, "
            to_header="$to_header$addr"
        done

        local from_addr="${SMTP_FROM:-$SMTP_USER}"

        curl -sf -o /dev/null \
            --url "smtp://${SMTP_HOST}:${SMTP_PORT:-587}" \
            --ssl-reqd \
            --mail-from "$from_addr" \
            $rcpt_args \
            --user "$SMTP_USER:$SMTP_PASS" \
            -T - <<EMAIL 2>/dev/null || log "WARNING: email notification failed"
From: WESS Monitor <$from_addr>
To: $to_header
Subject: $subject
Content-Type: text/plain; charset=utf-8

$body

--
WESS Health Monitor | $(hostname) ($(curl -sf --max-time 3 ifconfig.me 2>/dev/null || echo "unknown"))
EMAIL
    fi
}

notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-high}"
    local tags="${4:-warning}"

    send_ntfy "$title" "$message" "$priority" "$tags"
    send_email "[WESS] $title" "$message"
}

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
    status=$(sudo docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "not_found")

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

# Check disk space (alert if >85% used)
DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
if [ "$DISK_USAGE" -gt 85 ]; then
    DETAILS="$DETAILS  ✗ Disk usage: ${DISK_USAGE}% (threshold: 85%)\n"
    FAILURES=$((FAILURES + 1))
else
    DETAILS="$DETAILS  ✓ Disk usage: ${DISK_USAGE}%\n"
fi

# Check database connectivity
if sudo docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T postgres pg_isready -U wess -d wess >/dev/null 2>&1; then
    DETAILS="$DETAILS  ✓ PostgreSQL accepting connections\n"
else
    DETAILS="$DETAILS  ✗ PostgreSQL not responding\n"
    FAILURES=$((FAILURES + 1))
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
        CSTATUS=$(sudo docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
        if [ "$CSTATUS" != "running" ] && [ "$CSTATUS" != "not_found" ]; then
            log "Attempting to restart $container..."
            sudo docker start "$container" 2>/dev/null || true
        fi
    done
fi

# Save current state for next run's comparison
echo "$STATUS" > "$PREV_STATUS_FILE"

# Write full status file (can be read by external monitors)
echo "$TIMESTAMP | $STATUS" > "$STATUS_FILE"
echo -e "$DETAILS" >> "$STATUS_FILE"
