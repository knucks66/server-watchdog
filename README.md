# Server Watchdog

Automated health monitoring for the Hetzner server. Runs via GitHub Actions (free on public repos).

## Workflows

### 1. Server Health Check & Auto-Reboot (`health-check.yml`)

Runs every **5 minutes**. Checks HTTP endpoints for connectivity.

- If all endpoints are unreachable, waits 60s and rechecks (avoids false positives)
- If still down, triggers a soft reboot via the Hetzner Cloud API
- Verifies the server comes back online

**Monitored endpoints:**
- `api.slotland.rumio.world`
- `api.axiss.rumio.world`
- `api.taxengine.rumio.world`

### 2. Container Health & Dependency Check (`container-health.yml`)

Runs every **10 minutes**. SSHes into the server and checks container-level health.

Catches issues the endpoint check can't — like a container that's running but has lost its database connection (e.g., SuperTokens after Postgres is recreated).

**What it checks:**
- SuperTokens → Postgres connectivity (JWKS endpoint vs hello endpoint)
- Hasura → Postgres connectivity (healthz endpoint)
- Postgres start time vs dependent containers (detects stale DNS after Postgres recreation)

**Remediation:** Restarts only the affected container(s) via `docker compose restart` — no full server reboot needed.

## Required secrets

| Secret | Used by | Description |
|--------|---------|-------------|
| `HETZNER_API_TOKEN` | health-check | Hetzner Cloud API token (read/write) |
| `HETZNER_SERVER_ID` | health-check | Hetzner server ID |
| `SSH_PRIVATE_KEY` | container-health | Ed25519 private key for root@server |
| `SERVER_IP` | container-health | Server IP address (e.g., `178.156.198.221`) |
