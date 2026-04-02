# Server Watchdog

Automated health monitoring for the Hetzner server. Runs via GitHub Actions (free on public repos).

## Workflows

### 1. Server Health Check & Auto-Reboot (`health-check.yml`)

Runs every **5 minutes**. Checks HTTP endpoints from `endpoints.yml`.

- If all endpoints are unreachable, waits 60s and rechecks (avoids false positives)
- If still down, triggers a soft reboot via the Hetzner Cloud API
- Verifies the server comes back online

**Adding endpoints:** Edit `endpoints.yml` or use the site creation wizard (auto-registers new sites).

### 2. Container Health & Dependency Check (`container-health.yml`)

Runs every **10 minutes**. SSHes into the server and checks container-level health.

**What it checks:**
- SuperTokens → Postgres connectivity (JWKS endpoint vs hello endpoint)
- Hasura → Postgres connectivity (healthz endpoint)
- Postgres start time vs dependent containers (detects stale DNS after Postgres recreation)
- **All containers with Docker health checks** — detects and restarts any container reporting `unhealthy`

**Remediation:** Restarts only the affected container(s) via `docker compose restart` (uses compose labels to find the right project/file). No full server reboot needed.

### 3. Resource Monitor & Cleanup (`resource-monitor.yml`)

Runs every **2 hours**. SSHes into the server and monitors resource usage.

**What it checks:**
- Disk usage (auto-cleanup at >=85%: prunes images, build cache, unused volumes)
- RAM and swap usage (warns when critically low, drops caches at >=95% swap)
- Zombie processes (auto-restarts parent containers when >100 zombies detected)
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
