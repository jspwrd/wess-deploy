#!/bin/bash
# Cron job to sync TLE data daily
# Add to crontab: 0 4 * * * /home/jsprd/dev/projects/repos/wess-deploy/scripts/sync-tles.sh >> /var/log/auto-tle-sync.log 2>&1

cd /home/jsprd/dev/projects/repos/wess-deploy
sudo docker compose run --rm auto-tle
