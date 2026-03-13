# Server Watchdog

Automated health monitoring for the Hetzner server. Runs via GitHub Actions (free on public repos).

## Workflows

### 1. Server Health Check & Auto-Reboot (`health-check.yml`)

Runs every **5 minutes**. Checks HTTP endpoints for all projects.

- If all endpoints are unreachable, waits 60s and rechecks (avoids false positives)
- If still down, triggers a soft reboot via the Hetzner Cloud API
- Verifies the server comes back online

**Monitored endpoints:**
- `api.slotland.rumio.world` — Slotland
- `api.axiss.rumio.world` — AXISS
- `api.taxengine.rumio.world` — TaxEngine
- `api.podcastwiz.rumio.world` — PodcastWiz
- `api.hhm.rumio.world` — HHM
- `api.lsg.rumio.world` — LSG
- `api.daytradepro.rumio.world` — DayTradePro
- `ai-forge.rumio.world` — AI Forge
- `ownersbox.rumio.world` — OwnersBox

### 2. Container Health & Dependency Check (`container-health.yml`)

Runs every **10 minutes**. SSHes into the server and checks container-level health.

**What it checks:**
- SuperTokens → Postgres connectivity (JWKS endpoint vs hello endpoint)
- Hasura → Postgres connectivity (healthz endpoint)
- Postgres start time vs dependent containers (detects stale DNS after Postgres recreation)
- **All containers with Docker health checks** — detects and restarts any container reporting `unhealthy`

**Remediation:** Restarts only the affected container(s) via `docker compose restart` (uses compose labels to find the right project/file). No full server reboot needed.

### 3. Resource Monitor & Cleanup (`resource-monitor.yml`)

Runs every **6 hours**. SSHes into the server and monitors resource usage.

**What it checks:**
- Disk usage (auto-cleanup at ≥85%: prunes images, build cache, unused volumes)
- RAM and swap usage (warns when critically low)
- Docker resource breakdown (images, containers, volumes, build cache)
- Container memory/CPU usage (top 10)
- Orphan containers (from deleted/moved compose files) — auto-removes them

## Required secrets

| Secret | Used by | Description |
|--------|---------|-------------|
| `HETZNER_API_TOKEN` | health-check | Hetzner Cloud API token (read/write) |
| `HETZNER_SERVER_ID` | health-check | Hetzner server ID |
| `SSH_PRIVATE_KEY` | container-health, resource-monitor | Ed25519 private key for root@server |
| `SERVER_IP` | container-health, resource-monitor | Server IP address |
