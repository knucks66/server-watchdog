# Server Watchdog

Automated health monitoring for the Hetzner server. Runs every 5 minutes via GitHub Actions (free on public repos).

## How it works

1. Checks API endpoints for connectivity
2. If all endpoints are unreachable, waits 60s and rechecks (avoids false positives)
3. If still down, triggers a soft reboot via the Hetzner Cloud API
4. Verifies the server comes back online

## Required secrets

- `HETZNER_API_TOKEN` — Hetzner Cloud API token with read/write access
- `HETZNER_SERVER_ID` — Hetzner server ID
