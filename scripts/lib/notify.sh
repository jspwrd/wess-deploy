#!/bin/bash
# Shared notification helpers (ntfy.sh + email via SMTP).
# Callers must source the deploy .env first so NTFY_TOPIC / SMTP_* /
# ALERT_EMAILS are set, then: source "$(dirname "$0")/lib/notify.sh"

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
            "https://ntfy.sh/$NTFY_TOPIC" 2>/dev/null \
            || echo "[notify] WARNING: ntfy notification failed"
    fi
}

send_email() {
    local subject="$1"
    local body="$2"

    if [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_USER:-}" ] && [ -n "${SMTP_PASS:-}" ]; then
        local recipients="${ALERT_EMAILS:-$SMTP_USER}"
        local rcpt_args=""
        local to_header=""

        IFS=',' read -ra ADDRS <<< "$recipients"
        for addr in "${ADDRS[@]}"; do
            addr=$(echo "$addr" | xargs)
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
            -T - <<EMAIL 2>/dev/null || echo "[notify] WARNING: email notification failed"
From: WESS Monitor <$from_addr>
To: $to_header
Subject: $subject
Content-Type: text/plain; charset=utf-8

$body

--
WESS Monitor | $(hostname)
EMAIL
    fi
}

# notify <title> <message> [priority] [tags]  — ntfy + email
notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-high}"
    local tags="${4:-warning}"

    send_ntfy "$title" "$message" "$priority" "$tags"
    send_email "[WESS] $title" "$message"
}

# notify_quiet <title> <message> [priority] [tags] — ntfy only, for
# routine events (successful deploys) that shouldn't generate email.
notify_quiet() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-information_source}"

    send_ntfy "$title" "$message" "$priority" "$tags"
}
