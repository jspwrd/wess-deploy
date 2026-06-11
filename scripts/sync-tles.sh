#!/bin/bash
# Daily TLE data sync (cron: 0 4 * * *). Pulls the latest AutoTLE image
# if the registry is reachable, then runs the one-shot sync.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$(dirname "$SCRIPT_DIR")/docker-compose.yml"

docker compose -f "$COMPOSE_FILE" pull auto-tle 2>/dev/null \
    || echo "[sync-tles] pull failed; using local image"
docker compose -f "$COMPOSE_FILE" run --rm auto-tle
