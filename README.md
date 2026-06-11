# wess-deploy

Production deployment for [wess.jsprd.io](https://wess.jsprd.io) — control
plane only. No application source lives on this host; prod runs prebuilt
images from ghcr.io.

## Architecture

```
push to main ──► GitHub Actions (CI: lint+test, then build & push image)
                      │  workflow_run (success) webhook, HMAC-signed
                      ▼
   Cloudflare ──► nginx ──► webhook container ──► deploy.sh
                                                    │ docker compose pull <svc>
                                                    │ docker compose up -d <svc>
                                                    │ health gate ──► auto-rollback
                                                    ▼
              ntfy.sh + email notification (success, skip, or failure)
```

| Service       | Image                              | Built by                     |
|---------------|------------------------------------|------------------------------|
| wess-frontend | `ghcr.io/jspwrd/wess:main`         | wess `Deploy` workflow       |
| wess-backend  | `ghcr.io/jspwrd/wess-backend:main` | wess-backend `Deploy` workflow |
| auto-tle      | `ghcr.io/jspwrd/autotle:latest`    | AutoTLE `CI` workflow        |
| webhook       | built locally from `./webhook`     | this repo                    |
| nginx, postgres | upstream images                  | —                            |

A failed CI run never deploys: the webhook only acts on
`workflow_run` events with `conclusion=success` on `main`, and the GitHub
webhook signature is verified (the listener refuses to start without
`WEBHOOK_SECRET`).

## Deploy flow details

- `deploy.sh <repo>` pulls the service's image. Unchanged digest → no-op.
- The outgoing image is tagged `:previous` before the swap.
- After `up -d` the container must reach Docker `healthy` (or stay running
  15s if the image has no healthcheck) within 120s, or deploy.sh re-tags
  `:previous` back and restarts — automatic rollback, with an urgent
  notification.
- Deploys are serialized with a lock (5 min wait).
- AutoTLE "deploys" = pull image + run the one-shot sync.

## Runbook

```bash
# Manual deploy (same path the webhook takes)
scripts/deploy.sh wess|wess-backend|AutoTLE|all

# Manual rollback to the previous image
scripts/rollback.sh wess|wess-backend

# What is deployed right now?
docker image inspect ghcr.io/jspwrd/wess:main ghcr.io/jspwrd/wess-backend:main \
  --format '{{index .RepoTags 0}} -> {{index .Config.Labels "org.opencontainers.image.revision"}}'

# Deploy/webhook logs
docker logs wess-deploy-webhook-1 --tail 100

# Health status (written every 5 min by cron)
cat /var/log/wess/health-status

# DB backup / restore
scripts/backup-db.sh
scripts/restore-db.sh /var/backups/wess-postgres/daily/<file>.sql.gz
```

## Cron (user crontab)

```
0 4 * * *   scripts/sync-tles.sh            # daily TLE data sync
30 2 * * *  scripts/backup-db.sh            # daily DB backup (7d + 4w rotation)
*/5 * * * * scripts/health-check.sh         # monitor + alert + auto-restart
0 3 1 * *   scripts/update-cloudflare-ips.sh# refresh CF ip allowlist
```

All cron logs: `/var/log/wess/*.log` (dir must be owned by the cron user —
root-owned log paths were why monitoring silently never ran before).

## GitHub-side configuration (required)

1. **Webhook** on each repo (wess, wess-backend, AutoTLE):
   `https://wess.jsprd.io/webhook`, content type `application/json`,
   secret = `WEBHOOK_SECRET` from `.env`, events: **Workflow runs** only.
2. **Package access**: images on ghcr.io must be pullable from this host —
   either make each package public (Package → Settings → Change visibility)
   or `docker login ghcr.io` here with a PAT that has `read:packages`.

## Notes

- `docker-compose.yml` pins `name: wess-deploy` and the postgres volume
  name. Don't remove these; container names and the data volume depend on
  them, not on this directory's path.
- The webhook container mounts this directory read-only at the same
  absolute path as the host so compose-relative bind paths stay valid.
- AutoTLE's `sync.yml` (6-hourly sync from GitHub runners) cannot reach
  the database — postgres is intentionally not exposed. The local cron is
  the real sync; consider deleting sync.yml in the AutoTLE repo.
- `.env` holds secrets (postgres password, webhook secret, SMTP). Keep it
  mode 600; it is gitignored.
