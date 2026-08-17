# Spec: systemd-logind leaked-session reaper

**Status:** implemented (`logind-reaper.yml` + `scripts/logind-reaper.sh` +
`systemd/logind-reaper.{service,timer}` + `scripts/install-logind-reaper.sh`).
**Author:** durable fix for the logind fd/session leak cleared manually on
2026-06-16.
**Owner:** server-watchdog (host-level recovery with root — the watchdog's charter).

## Background — the failure this addresses

`systemd-logind` on the production Hetzner box (`5.161.89.74`) leaks **sessions
stuck in `State=closing` with `Leader=0` (the leader process is long dead)** that
it never reaps. Each leaked session holds an `anon_inode:[pidfd]` fd in logind's
process. They accumulate until logind hits **8,192 open fds = the login ceiling**,
after which new logins / `docker exec` start failing. This is the known
**systemd 255 logind bug**.

On the morning of 2026-06-16, logind held **8,213 fds (8,193 leaked pidfds) /
"8192 users"** with `who` = 0 real sessions. It was cleared manually with
`systemctl restart systemd-logind` (fds 8,213 → 21). Without a reaper it
re-accrues to the ceiling.

### Why the obvious fixes don't apply

- **Not fixable by upgrade.** The host is already on `systemd
  255.4-1ubuntu8.16` (latest noble patch — `apt-get -s upgrade` offers no
  systemd-daemon upgrade).
- **Not a CI mistake.** The ownersbox deploy workflow already SSHes **without a
  PTY** (heredoc to stdin, no `-t`/`-tt`) in a **single** login. The leak is
  host-wide — the oldest stuck session observed was from a **residential
  interactive SSH on 2026-04-04** (73 days stuck, `Leader=0`,
  `RemoteHost=98.250.200.244`), not CI. Any sshd login can trip it.
- **Config knobs don't help.** `KillUserProcesses` / `StopIdleSessionSec` /
  `UserStopDelaySec` are all default and irrelevant: the stuck sessions have
  **no processes left to kill** — they're orphaned in logind's state machine.
- **ownersbox's `fd_exhaustion` alert won't catch it.** It reads the
  **system-wide** `/proc/sys/fs/file-nr` ratio, which stays near 0% even when
  one process (logind) hoards 8k fds. (Dashboard-native detection would need a
  new per-process/logind fd metric; the watchdog detect→remediate→report path
  here makes that optional.)

**Therefore the fix is a periodic reaper in the watchdog:** detect the buildup,
clear it, and report the action up to JARVIS so it's never silent again.

### Evidence (live host, 2026-06-16 ~23:00 UTC, ~14 h after the manual restart)

```
systemd 255 (255.4-1ubuntu8.16)        # latest noble; no upgrade available
logind fd count: 23                    # healthy right after restart...
total sessions: 2  ->  1 active, 1 closing   # ...but already 1 leaked session re-accrued
closing session #887:
    Timestamp=Sat 2026-04-04 04:26:05 UTC    # stuck 73 days
    Leader=0                                  # leader process long dead
    Service=sshd  Type=tty  Remote=yes  RemoteHost=98.250.200.244   # residential, NOT CI
    State=closing
```

The restart is proven safe: live SSH was not dropped and all Docker containers
stayed healthy.

## Goals

1. Detect logind fd buildup with a huge margin under the 8,192 ceiling.
2. Remediate it — surgically first, reliably second — without disrupting live
   logins or containers.
3. Report every reap to JARVIS via the existing Ownersbox bridge so the leak is
   never silent again.

## Non-goals

- A systemd/CI fix (dead ends — see above).
- A box reboot (kept in `health-check.yml` for a fully wedged box; irrelevant
  here — restarting logind is enough and far less disruptive).

---

## Detection (read-only, every run)

Two cheap signals; the engine keys on whichever fires first:

```sh
# Direct danger metric: logind's open fd count vs the 8192 ceiling
LPID=$(systemctl show -p MainPID --value systemd-logind)
FDS=$(ls /proc/"$LPID"/fd 2>/dev/null | wc -l)

# Leading indicator: sessions stuck closing with a dead leader (the leaked ones)
for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
  st=$(loginctl show-session "$s" -p State --value)
  ld=$(loginctl show-session "$s" -p Leader --value)
  [ "$st" = closing ] && [ "$ld" = 0 ] && echo "$s"   # a leaked session id
done
```

### Thresholds (huge margin under the 8192 ceiling)

| Env | Default | Meaning |
|---|---|---|
| `FD_WARN` | 1000 | warn-only report at/above this fd count |
| `FD_ACT` | 2000 | act (surgical first) at/above this fd count |
| `FD_RESTART` | 4000 | skip straight to restarting logind at/above this |
| `LEAKED_ACT` | 200 | act when this many leaked sessions are counted |
| `COOLDOWN_SECS` | 1800 | min seconds between remediations (anti-flap) |

8,192 took ~75 days to fill (mostly a CI burst); `FD_ACT=2000` still leaves weeks
of headroom and fires long before any login can break. `FD_WARN` gives a
visibility-only heads-up before any action.

## Remediation (escalating; at most one action per run; cooldown-guarded)

1. **Surgical first** — for each leaked session id, `loginctl terminate-session
   <id>`. On systemd 255.4 this frequently does **not** clear a `Leader=0`
   closing session (that's the bug), so the engine re-reads `FDS` after a short
   pause and escalates if it didn't drop.
2. **Reliable clear** — `systemctl restart systemd-logind`. **Proven safe on
   this host (2026-06-16):** active SSH sessions survive, Docker containers are
   untouched, only the leaked session state is dropped (fds 8,213 → 21). No
   maintenance window needed. This is the **primary** action past `FD_RESTART`
   and the **fallback** when step 1 doesn't bring `FDS` down.

### Safety rules (enforced by the engine)

- **Only ever target `State=closing` + `Leader=0`.** The engine collects
  exactly those ids and terminates only them — never an `active`/`online`
  session (which could be a live login, possibly the watchdog's own).
- **One remediation per run**, plus a `COOLDOWN_SECS` cooldown shared across
  Layers 2 and 3 (via the flock + `/run/logind-reaper.cooldown`) so a flapping
  count can't loop-restart logind.
- After acting, **report to JARVIS** (`logind-reaper` layer, `action`
  `terminate_sessions(N)` or `restarted_logind`, with `fds X→Y`).

---

## Layers (mirrors the load-guard three-layer design)

### Layer 2 — `logind-reaper.yml` (cloud cadence + alerting)

Every **30 minutes** (`cron: '*/30 * * * *'`), pipes the repo's engine over SSH
to the box and runs it as root, parses the `RESULT` line, and sends a **Discord**
push on state change (deduped via `/run/logind-reaper.alerted`: `OK` / `WARN` /
`CRITICAL` / `REAPED`). The cadence is intentionally slow — the leak is glacial,
the threshold leaves weeks of headroom, and each run is itself an SSH login (the
very thing that rarely seeds the leak), so there's no reason to churn logins.

### Layer 3 — on-box systemd timer (local fail-safe)

`logind-reaper.{service,timer}` run the same engine every **15 minutes** on the
box (`scripts/install-logind-reaper.sh`). This path:

- costs **no SSH login** (so it never adds to the leak it's clearing), and
- keeps working even if the box can't reach GitHub — and is the **only** path
  that still works if fds ever did approach the ceiling and started **refusing
  new SSH logins** (which would lock Layer 2 out exactly when it's needed).

The two cadences coordinate via a flock + the shared cooldown statefile, so they
never double-act.

### Reporting to JARVIS

The engine's `emit()` pushes to Ownersbox on **interventions only** (a reap, or
a critical it couldn't clear) — not on quiet ok/warn runs. Warn state-change
alerting is handled by the Layer 2 Discord path, and liveness by load-guard's
heartbeat + the pulled GitHub Actions run status, so the reaper deliberately
does **not** add a third heartbeat stream. Set `OBX_WEBHOOK_URL` + `OBX_TOKEN`
(repo secrets for Layer 2; `/etc/load-guard.env` or `/etc/logind-reaper.env` for
Layer 3) to enable; absent them, detection and remediation still run.

## Validation plan

1. **Detection:** on the box, `systemctl show -p MainPID --value systemd-logind`
   then `ls /proc/<pid>/fd | wc -l` — confirm the engine's `logind_fds` matches.
2. **Leaked count:** confirm the engine's `leaked` count matches a manual
   `loginctl list-sessions` sweep for `State=closing` + `Leader=0`.
3. **Surgical path:** temporarily lower `FD_ACT` below the current fd count with
   the current count under `FD_RESTART`; confirm the engine runs
   `terminate-session` on the leaked ids only, leaves active sessions alone, and
   escalates to a logind restart if the count doesn't drop.
4. **Restart path & safety:** with `FD_RESTART` crossed, confirm the engine
   restarts logind, that the running SSH session survives, that `docker ps`
   stays healthy, and that `fds` drops to the ~20s. Confirm the cooldown blocks
   a second restart on the next tick.
5. **Negative:** healthy box (fds < `FD_WARN`) → `action=none level=ok`, no
   Discord alert, no Ownersbox push.

## Open questions

- Long term, is there an upstream systemd backport that fixes the
  closing/`Leader=0` reap bug? Re-check on the next noble systemd bump; if fixed,
  this reaper becomes a no-op safety net rather than a load-bearing fix.
- Session **#887** (the 73-day straggler) is the canary; the first reap (or any
  logind restart) clears it. Harmless until then.
