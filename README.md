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
- Wyze Bridge HTTP health (file descriptor exhaustion, crashes)
- Wyze Bridge motion-event staleness — detects when the bridge's cloud Events API subscription silently drifts (HTTP stays 200, but `motion_ts` frozen across all cameras for >6h). Vigil's recorder is motion-gated, so this failure produces zero clips with no error logs. Restarts the bridge to refresh the subscription.
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

### 4. Load Guard (`load-guard.yml`)

Runs every **5 minutes**. Runs the shared guard engine (`scripts/load-guard.sh`)
on the box and sends ntfy push alerts on state changes.

**What it checks:** 1-min load (critical at `cores × 4`), `MemAvailable`, swap %
(swap only counts when MemAvailable is also low — avoids stale-swap false
positives). Debounces over two consecutive samples so a momentary spike doesn't
trigger.

**Remediation (only on sustained critical):**
- Restarts postgres if it has gone unhealthy (the victim), via compose labels.
- Does NOT kill builds box-wide — Layer 1's `runners.slice` cap contains runaway
  *builds* structurally, and `pkill esbuild` would hit vitest/CI. An opt-in
  `SHED_BUILDS=1` backstop targets only `vite build`/`npm run build` inside
  `runners.slice`.

The same engine runs on-box every **2 minutes** via a systemd timer (Layer 3,
`scripts/install-load-guard.sh`) — the fast local fail-safe for when GitHub
deprioritizes the scheduled run under load. The two cadences coordinate via a
flock + statefile. Alerting is ntfy push, state-change-deduplicated.

## Runner memory cap (cgroup slice)

The self-hosted GitHub Actions runners share the production box. Without a
limit, a runaway build (e.g. a many-way parallel `vite build` matrix) can eat
all RAM + swap and OOM-kill production services — this caused a fleet-wide
outage on 2026-05-28.

`scripts/apply-runner-cgroup-limits.sh` puts every `actions.runner.*` unit in a
shared `runners.slice` with a hard `MemoryMax`, so runner builds can never
exceed their budget and starve prod. Idempotent; run as root on the server.
Busy runners are skipped (so in-flight CI isn't killed) and adopt the slice on
their next restart — re-run when they're idle. See
[`docs/load-guard-spec.md`](docs/load-guard-spec.md) for the full design
(Layer 1), plus the planned detection/remediation workflow (Layer 2) and on-box
fail-safe (Layer 3).

## Required secrets

| Secret | Used by | Description |
|--------|---------|-------------|
| `HETZNER_API_TOKEN` | health-check | Hetzner Cloud API token (read/write) |
| `HETZNER_SERVER_ID` | health-check | Hetzner server ID |
| `SSH_PRIVATE_KEY` | container-health, resource-monitor, load-guard | Ed25519 private key for root@server |
| `SERVER_IP` | container-health, resource-monitor, load-guard | Server IP address |
| `NTFY_URL` | load-guard | Full ntfy topic URL (e.g. `https://ntfy.sh/<private-topic>`) for push alerts (optional — detection/remediation run without it) |
| `OBX_WEBHOOK_URL` | all | Ownersbox ingest endpoint `https://ownersbox.rumio.world/api/watchdog/event` (optional — feeds JARVIS) |
| `OBX_TOKEN` | all | Ownersbox agent token (`obx_…`) for the `watchdog` agent, `event:write` scope (optional) |

### Feeding the Ownersbox dashboard (JARVIS)

When `OBX_WEBHOOK_URL` and `OBX_TOKEN` are set as repo secrets, every workflow
POSTs a structured event to Ownersbox so its JARVIS AI layer gains real-time
awareness of what the watchdog detected and did — host reboots, container
restarts, cleanups, and load-guard criticals. (The on-box load-guard timer —
Layer 3 — runs the same engine and will also report once those two vars are in
its service environment, e.g. via a systemd `EnvironmentFile`; not wired by
default.) This is purely additive:
detection and remediation run regardless, and Ownersbox also pulls this repo's
GitHub Actions run status independently so it can tell when the watchdog has
stopped running entirely. Mint the token from the Ownersbox dashboard
(Agents → watchdog → tokens, `event:write` scope).
