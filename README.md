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
- Disk usage (auto-cleanup at >=85%: prunes images, build cache, and
  **anonymous** volumes only — named volumes are reported, never deleted)
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

### 5. Logind Reaper (`logind-reaper.yml`)

Runs every **30 minutes**. Runs the shared reaper engine
(`scripts/logind-reaper.sh`) on the box and sends ntfy push alerts on state
changes.

**The problem it fixes:** `systemd-logind` (systemd 255) leaks sessions stuck in
`State=closing` with `Leader=0` — the leader process is dead but logind never
reaps them, and each holds a `pidfd`. They accumulate until logind hits **8,192
open fds = the login ceiling**, after which new SSH logins / `docker exec` start
failing. Not fixable by upgrade (already on the latest noble patch), not a CI
mistake (the leak is host-wide — the oldest observed straggler was a residential
SSH stuck 73 days), and ownersbox's system-wide `fd_exhaustion` alert can't see
it (one process hoarding 8k fds barely moves the box-wide ratio).

**What it checks:** logind's open fd count (the direct danger metric) and the
count of sessions stuck `closing` + `Leader=0` (the leaked ones).

**Remediation (only past threshold, at most once per run, cooldown-guarded):**
- **Surgical first:** `loginctl terminate-session` each leaked id (only ever
  `closing`+`Leader=0` — never a live session).
- **Reliable fallback / primary past a higher threshold:** `systemctl restart
  systemd-logind` — proven safe on this host (active SSH survives, containers
  untouched, fds 8,213 → 21).

The same engine runs on-box every **15 minutes** via a systemd timer (Layer 3,
`scripts/install-logind-reaper.sh`) — costs no SSH login and is the only path
that still works if fds ever approached the ceiling and started refusing logins.
See [`docs/logind-reaper-spec.md`](docs/logind-reaper-spec.md).

### 6. Kernel Reboot (`kernel-reboot.yml`)

Runs **weekly, Sundays 05:00 UTC**. Reboots the box onto a pending kernel, but
only when it is genuinely safe to do so.

**The problem it fixes:** `unattended-upgrades` is installed and enabled, and it
faithfully *installs* security updates including kernels — but it has no
`Automatic-Reboot` setting, so nothing ever activates them. On 2026-08-05 the box
had been up **17 weeks** running `6.8.0-106` with `6.8.0-136` installed and
`/var/run/reboot-required` set: 30 kernel versions plus a `libc6` update sitting
dormant. Security patches you have downloaded but never booted are not applied.

**Why not just set `Unattended-Upgrade::Automatic-Reboot "true"`:** a blind
reboot at a fixed hour would kill in-flight CI across the 21 self-hosted runners
(the 3-shard suite runs 1-2h), and can land inside the 03:00-03:20 nightly backup
window — the `vigil_app` dump alone is ~4.5 GB and takes most of it.

**Guards (all must pass; any failure postpones to next week and exits 0):**
- `/var/run/reboot-required` exists — otherwise there is nothing to do
- no `Runner.Worker` processes (no CI job in flight)
- no `pg_dump` / backup script running
- no `docker build` / `docker compose up` (no deploy mid-recreate)
- no failed systemd units — never reboot on top of an existing fault

**Sequence:** stop runners → `docker compose stop` (graceful Postgres; never
`down --remove-orphans`, which reaps docker-run containers including Postgres) →
Hetzner API soft reboot → wait for SSH → `compose start` → `docker start
pg-ci-proxy` (the one container with restart policy `no`) → restart runners →
verify container count, swap, and every endpoint in `endpoints.yml`.

`workflow_dispatch` accepts `force: true` to override the idle guards (still
requires a pending reboot) for a deliberate manual window.

> **Counting convention in the guards.** Patterns are written `[R]unner.Worker`,
> `[p]g_dump` and counted with `| wc -l`. Both halves are load-bearing: without
> the bracket, `pgrep -f 'pg_dump'` matches the SSH command line *asking the
> question*, so the backup guard reports a backup running 24/7 and the reboot is
> postponed forever. And `grep -c`/`pgrep -c` exit non-zero on no-match, so the
> natural `$(... || echo 0)` emits **two** lines (`0
0`) — which compares as
> non-zero and trips the guard it was meant to clear. Both bugs were caught by
> dry-running the guards against the live box; both fail *closed* (never reboot),
> which is why they would have gone unnoticed indefinitely.

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
| `SSH_PRIVATE_KEY` | container-health, resource-monitor, load-guard, logind-reaper | Ed25519 private key for root@server |
| `SERVER_IP` | container-health, resource-monitor, load-guard, logind-reaper | Server IP address |
| `NTFY_URL` | load-guard, logind-reaper | Full ntfy topic URL (e.g. `https://ntfy.sh/<private-topic>`) for push alerts (optional — detection/remediation run without it) |
| `OBX_WEBHOOK_URL` | all | Ownersbox ingest endpoint `https://ownersbox.rumio.world/api/watchdog/event` (optional — feeds JARVIS) |
| `OBX_TOKEN` | all | Ownersbox agent token (`obx_…`) for the `watchdog` agent, `event:write` scope (optional) |

### Feeding the Ownersbox dashboard (JARVIS)

When `OBX_WEBHOOK_URL` and `OBX_TOKEN` are set as repo secrets, the watchdog
POSTs to Ownersbox so its JARVIS AI layer sees what it detected and did — host
reboots, container restarts, cleanups, load-guard criticals. Only *interventions*
are pushed as events (a quiet healthy run is not), keeping the event log a clean
record of action. Liveness is handled two ways: Ownersbox pulls this repo's
GitHub Actions run status (so it knows the cloud cadence is running), and the
load-guard engine emits a low-frequency `heartbeat` event (≤ once per
`OBX_HEARTBEAT_SECS`, default 15 min) — an independent signal that survives
GitHub deprioritizing the scheduled run and confirms the on-box fail-safe.

The on-box load-guard timer (Layer 3) reports too: pass
`OBX_WEBHOOK_URL`/`OBX_TOKEN` to `install-load-guard.sh` and it writes them 0600
to `/etc/load-guard.env`, which the service loads via `EnvironmentFile`. This is
purely additive — detection and remediation run regardless. Mint the token from
the Ownersbox dashboard (Agents → watchdog → tokens, `event:write` scope).

The on-box logind-reaper timer works the same way via
`install-logind-reaper.sh`. It loads **both** `/etc/load-guard.env` and an
optional reaper-specific `/etc/logind-reaper.env`, so if load-guard is already
installed with creds, the reaper inherits them automatically — no need to
re-enter the token.
