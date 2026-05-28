# Spec: Memory & Load Pressure Guard

**Status:** Layer 1 applied; Layers 2 & 3 implemented (`load-guard.yml` +
`scripts/load-guard.sh` + `systemd/load-guard.{service,timer}`).
**Author:** follow-up to the 2026-05-28 fleet-wide outage
**Owner:** server-watchdog

## Background — the failure this addresses

On 2026-05-28 a push to `rumio:main` triggered `deploy-frontend.yml`, which fans out a **16-tenant `vite build` matrix onto the self-hosted runners that live on the production Hetzner box**. The parallel builds exhausted RAM + swap and the kernel OOM-killer fired:

```
03:02:37 oom-killer: task_memcg=/system.slice/actions.runner.knucks66-rumio.hetzner-runner-rumio-3.service, task=node
Out of memory: Killed process (node) total-vm:26.7 GB anon-rss:2.4 GB
```

Cascade: load average hit **280 on an 8-core box (~35×)**, swap went to **100% (2 GB)**, `infrastructure-postgres-1` became unresponsive → **every tenant API timed out → fleet-wide blank pages**. The same starvation knocked the self-hosted runner offline ("lost communication" deploy failures).

**The existing watchdog did not catch it:**

- `resource-monitor.yml` runs **every 2 h** — far slower than an OOM that develops in ~38 min. Its scheduled GitHub run was also delayed (GitHub deprioritizes `schedule:` workflows under load — exactly when you need them).
- It has **no load-average check** — the defining symptom (CPU/scheduler starvation) is unmeasured.
- Its only memory remediation is `echo 3 > drop_caches` at swap ≥95%, which frees **page cache** — useless against **anonymous** build-heap pressure. It would not have saved postgres.
- Nothing watches for the actual cause (runaway runner build processes) or protects the victim (postgres).

Box facts (for thresholds): **8 cores, ~15.6 GB RAM, 2 GB swap, ~8 GB baseline used by prod containers**, **17 self-hosted runner units** (3 of them `rumio`/`-2`/`-3`), all with `MemoryMax=infinity`.

## Goals

1. A runaway build (or any process group) must **never** be able to starve production containers.
2. Detect memory/load pressure within minutes and **remediate the cause, protect the victim**, then alert.
3. Survive the "GitHub starves the scheduled run" failure mode with an on-box fast path.

## Non-goals

- Replacing the Hetzner soft-reboot path in `health-check.yml` (kept as the last resort for a fully wedged box).
- Capacity planning / adding RAM (separate decision).

---

## Layer 1 — Hard cgroup cap on the runners (primary structural fix)

This is the definitive fix and is independent of any workflow logic. The OOM `task_memcg` shows each runner is its own systemd unit under `system.slice` with **no memory limit**. Bound the **aggregate** runner memory so builds physically cannot consume prod's headroom — a runaway then gets OOM-killed *inside the runners' own cgroup*, leaving postgres untouched.

**Approach: a shared slice for all runners** (per-unit caps don't bound the aggregate — 17 × 4 GB = 68 GB).

1. Create `/etc/systemd/system/runners.slice`:
   ```ini
   [Slice]
   MemoryAccounting=yes
   MemoryHigh=6G          # reclaim pressure kicks in here
   MemoryMax=7G           # hard ceiling for ALL runner builds combined
   CPUWeight=20           # prod (default 100) wins the scheduler under contention
   IOWeight=20
   ```
   Leaves ~8.5 GB for prod on a 15.6 GB box.

2. Drop-in for every `actions.runner.*` unit (templated; there are 17):
   ```ini
   # /etc/systemd/system/actions.runner.<unit>.service.d/slice.conf
   [Service]
   Slice=runners.slice
   ```
   Generate with a loop over `systemctl list-units 'actions.runner.*'`, then `systemctl daemon-reload` and restart the runner services.

3. **Validation:** start a deliberate memory hog inside a job, confirm it's killed when the slice hits 7 GB and that `free -m` / postgres health on the host are unaffected.

**Effect:** defense-in-depth with the `max-parallel: 2` cap already shipped in `deploy-frontend.yml` (rumio PR #236). Even if a future workflow forgets the cap, the slice contains the blast radius.

> Trade-off: builds may run slightly slower or get OOM-killed under the cap (surfaced as a failed CI job — recoverable) instead of taking down prod (an outage — not). Correct trade.

---

## Layer 2 — `load-guard.yml` workflow (the watchdog check requested)

A new, **fast-cadence** GitHub Actions workflow focused solely on the fast-moving memory/load failure. Keep the heavy 2 h `resource-monitor.yml` (docker df, stats, orphans) as-is.

**Cadence:** `cron: '*/5 * * * *'` (every 5 min, matching `health-check.yml`). Accept GitHub's schedule jitter; Layer 3 is the fast backstop.

**Setup step:** reuse the SSH-bootstrap + sentinel-check block verbatim from `resource-monitor.yml` (lines 12–28) so an SSH failure fails the run loudly instead of reporting all-zero metrics.

**Metrics (one SSH round-trip):**

| Metric | Source | Critical threshold (8-core box) |
|---|---|---|
| 1-min load | `awk '{print $1}' /proc/loadavg` | `load1 >= 32` (4× cores); warn at `>= 16` |
| MemAvailable | `free -m \| awk '/Mem:/{print $7}'` | `< 600 MB`; warn `< 1500 MB` |
| Swap used % | `free -m` Swap used/total | `>= 90%`; warn `>= 70%` |
| Runner build procs (cause) | procs whose cgroup matches `actions.runner.*` AND cmd `~ vite\|esbuild\|tsc\|rollup`, with RSS | informational + targets for remediation |
| postgres health (victim) | `docker inspect infrastructure-postgres-1 --format '{{.State.Health.Status}}'` | `!= healthy` |

**Debounce:** declare an incident only if **critical on two consecutive samples ~60 s apart** within one run (mirror `health-check.yml`'s 60 s recheck) — avoids acting on a transient spike.

**Remediation ladder (least → most aggressive; fix the cause, protect the victim):**

1. **Shed the cause.** If runner build procs are present and are top memory consumers: `pkill -TERM` then (after 5 s) `pkill -KILL` matching `esbuild` / `vite` / `rollup` build children. These are **build-only tools** — no production container runs them, so killing them is safe. Do **not** kill the runner *agent* (`Runner.Listener`/`Runner.Worker`); GitHub will just mark the job failed/cancelled.
   - ⚠️ Implementation note: the pkill pattern must not match the remediation shell itself (the 2026-05-28 manual fix killed its own SSH session because the command line contained `vite`). Use a bracket guard, e.g. `pkill -KILL -f '[e]sbuild'`, or match by cgroup path.
2. **Protect/restore the victim.** Re-check postgres health; if `!= healthy` or the SQL port is unresponsive, restart it via the compose-label pattern already in `container-health.yml` (`com.docker.compose.project.working_dir` + `service` → `docker compose restart`). postgres already has `restart: always`, but an explicit restart shortens recovery.
3. **Alert** (see below) on every action with before/after metrics.
4. **Do not** `drop_caches` here — it doesn't help anon-memory pressure. Keep that only in the existing swap step for genuinely cache-heavy swap.
5. **Escalate** to the Hetzner soft-reboot only via the existing `health-check.yml` path, and only when endpoints are fully unreachable (box wedged). Out of scope here.

**Idempotency / dedup:** follow the ownersbox philosophy — alert on **state change**, not every tick. Persist last-state in the workflow via a tiny marker file on the box (`/run/load-guard.state`) so repeated criticals don't spam.

---

## Layer 3 — On-box fast fail-safe (recommended)

GitHub `schedule:` runs are deprioritized exactly during high-load incidents (observed: 56-min gap during this outage). A tiny on-box timer guarantees a local response even when GitHub is slow and even if the box can't reach GitHub.

- `load-guard.service` + `load-guard.timer` (systemd, `OnUnitActiveSec=2min`) running a small `/opt/server-watchdog/load-guard.sh` that implements **only** ladder steps 1–2 above (shed builds, restart postgres if unhealthy) — no alerting (the GitHub layer owns alerts).
- Keep the script <60 lines, no external deps, guarded by a lockfile so it can't overlap.
- This is the component that would have auto-recovered 2026-05-28 within ~2 min without human intervention.

> If only one layer ships first, ship **Layer 1** (cgroup cap) — it prevents recurrence outright. Layer 3 is the best detection/recovery backstop; Layer 2 adds visibility + alerting.

---

## Changes to existing `resource-monitor.yml`

- Add the **load-average** metric (currently absent).
- Replace the swap-pressure remediation: `drop_caches` only when **cache is actually large** (`buff/cache` high); otherwise log "anon-memory pressure — see load-guard" rather than a no-op cache drop.
- Optionally drop its 2 h cadence to 30 min now that the fast path lives in `load-guard`.

---

## Alerting

`resource-monitor.yml` currently only `echo`s; there's no notify channel in this repo's secrets. ownersbox already posts to Discord. Two options:

1. Add a `DISCORD_WEBHOOK_URL` secret to server-watchdog and POST from `load-guard.yml` on any remediation.
2. Route through ownersbox's existing alert pipeline (it's the monitoring hub) via a small internal endpoint.

Recommend (1) for independence — the watchdog shouldn't depend on the thing it might be rescuing.

## Secrets

| Secret | New? | Used by |
|---|---|---|
| `SSH_PRIVATE_KEY`, `SERVER_IP` | existing | load-guard SSH |
| `DISCORD_WEBHOOK_URL` | **new** | load-guard alerting |
| `HETZNER_API_TOKEN`, `HETZNER_SERVER_ID` | existing | unchanged (reboot path stays in health-check) |

## Validation plan

1. **Layer 1:** in a throwaway CI job, `stress-ng --vm 2 --vm-bytes 4G --timeout 60s`; confirm the slice OOM-kills it at 7 GB and host `free -m` + `docker inspect postgres` stay healthy.
2. **Layer 2/3:** `stress-ng --cpu 16` to push load > 32; confirm the guard detects within one cycle, sheds (if build procs present) or logs, restarts postgres only if unhealthy, and emits exactly one Discord alert (not one per tick).
3. **Self-match regression:** confirm the pkill bracket-guard does not kill the guard's own shell.
4. **Negative:** healthy box → guard takes no action, no alert.

## Rollout order

1. Layer 1 cgroup slice (prevents recurrence; zero workflow risk).
2. Layer 3 on-box timer (fast local recovery).
3. Layer 2 workflow + Discord alerting (visibility).
4. Trim `resource-monitor.yml` swap remediation + add load metric.

## Open questions

- Slice ceiling: 7 GB assumes ~8 GB prod baseline. Re-measure prod steady-state before finalizing; leave ≥1 GB kernel/headroom.
- Should `deploy-frontend.yml` builds move **off** the prod box entirely (GitHub-hosted runners for the build job, self-hosted only for the deploy/wrangler step)? That would remove the failure class at the source; cost/network implications to evaluate separately.
