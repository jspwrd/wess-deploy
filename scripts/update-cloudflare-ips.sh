#!/bin/bash
# Updates iptables DOCKER-USER chain to only allow HTTP/HTTPS from Cloudflare IPs
# Also updates UFW rules if ufw is available
# Run monthly via cron to stay current with Cloudflare IP ranges
set -euo pipefail

LOG_PREFIX="[cloudflare-ips]"
log() { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') $*"; }

log "Fetching current Cloudflare IP ranges..."
CF_IPV4=$(curl -sf https://www.cloudflare.com/ips-v4/ || true)
CF_IPV6=$(curl -sf https://www.cloudflare.com/ips-v6/ || true)

if [ -z "$CF_IPV4" ]; then
    log "ERROR: Failed to fetch Cloudflare IPv4 ranges, aborting"
    exit 1
fi

# --- Update DOCKER-USER iptables chain ---
log "Rebuilding DOCKER-USER iptables chain..."

# Flush all existing DOCKER-USER rules
sudo iptables -F DOCKER-USER

# Re-add base rules (internal traffic, established connections)
sudo iptables -A DOCKER-USER -s 172.16.0.0/12 -j ACCEPT
sudo iptables -A DOCKER-USER -s 127.0.0.0/8 -j ACCEPT
sudo iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Add Cloudflare IPv4 ranges
CF4_COUNT=0
for ip in $CF_IPV4; do
    sudo iptables -A DOCKER-USER -s "$ip" -p tcp -m multiport --dports 80,443 -j ACCEPT
    CF4_COUNT=$((CF4_COUNT + 1))
done
log "Added $CF4_COUNT Cloudflare IPv4 ranges"

# Add Cloudflare IPv6 ranges (ip6tables)
CF6_COUNT=0
if [ -n "$CF_IPV6" ]; then
    # Flush and rebuild ip6tables DOCKER-USER too
    sudo ip6tables -F DOCKER-USER 2>/dev/null || true
    sudo ip6tables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    for ip in $CF_IPV6; do
        sudo ip6tables -A DOCKER-USER -s "$ip" -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null || true
        CF6_COUNT=$((CF6_COUNT + 1))
    done
    sudo ip6tables -A DOCKER-USER -p tcp -m multiport --dports 80,443 -j DROP 2>/dev/null || true
    sudo ip6tables -A DOCKER-USER -j RETURN 2>/dev/null || true
    log "Added $CF6_COUNT Cloudflare IPv6 ranges"
fi

# Drop everything else on 80/443 and return
sudo iptables -A DOCKER-USER -p tcp -m multiport --dports 80,443 -j DROP
sudo iptables -A DOCKER-USER -j RETURN

# Persist iptables rules
sudo netfilter-persistent save
log "iptables rules persisted"

# --- Update UFW rules if available ---
if command -v ufw &>/dev/null; then
    log "Updating UFW rules..."

    # Remove old Cloudflare UFW rules
    while sudo ufw status numbered 2>/dev/null | grep -q "Cloudflare"; do
        RULE_NUM=$(sudo ufw status numbered | grep "Cloudflare" | head -1 | grep -oP '^\[\s*\K[0-9]+')
        if [ -n "$RULE_NUM" ]; then
            sudo ufw --force delete "$RULE_NUM"
        else
            break
        fi
    done

    for ip in $CF_IPV4; do
        sudo ufw allow from "$ip" to any port 80,443 proto tcp comment "Cloudflare" 2>/dev/null || true
    done
    for ip in $CF_IPV6; do
        sudo ufw allow from "$ip" to any port 80,443 proto tcp comment "Cloudflare" 2>/dev/null || true
    done
    log "UFW rules updated"
fi

log "Done. $((CF4_COUNT + CF6_COUNT)) total Cloudflare IP ranges configured."
