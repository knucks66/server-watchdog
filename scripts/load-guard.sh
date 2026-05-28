#!/usr/bin/env bash
#
# Memory & Load Pressure Guard — engine (Layers 2 & 3, docs/load-guard-spec.md).
#
# Detects memory/load/swap pressure, debounces over two consecutive samples,
# then remediates: shed runaway *build* processes (the cause), and restart
# postgres if it's gone unhealthy (the victim). Emits one machine-readable
# `RESULT ...` line for callers (the Layer 2 workflow parses it to alert).
#
# Runs identically whether invoked by the on-box systemd timer (Layer 3) or
# piped over SSH by the GitHub workflow (Layer 2). A flock serializes the two
# cadences; a statefile carries the debounce across invocations.
#
# Must run as root (reads /proc, kills processes, restarts containers).
# No external dependencies beyond coreutils + docker + procps.
#
# Tunables (env), defaults sized for the 8-core / ~15.6 GB Hetzner box:
#   LOAD_CRIT_PER_CORE (default 4)   critical when load1 >= cores * this
#   MEM_CRIT_MB        (default 600) critical when MemAvailable below this
#   SWAP_CRIT_PCT      (default 90)  critical when swap used% at/above this
#   PG_CONTAINER       (default infrastructure-postgres-1)

set -uo pipefail   # NOT -e: pgrep/grep return nonzero on "no match"; we handle it.

LOCK=/run/load-guard.lock
STATE=/run/load-guard.state      # last classification (ok|critical) for debounce
LOG=/var/log/load-guard.log

LOAD_CRIT_PER_CORE="${LOAD_CRIT_PER_CORE:-4}"
MEM_CRIT_MB="${MEM_CRIT_MB:-600}"
SWAP_CRIT_PCT="${SWAP_CRIT_PCT:-90}"
PG_CONTAINER="${PG_CONTAINER:-infrastructure-postgres-1}"

# Serialize across the Layer 2 (5 min) and Layer 3 (2 min) cadences. If another
# instance holds the lock, skip this run — the holder is already on it.
exec 9>"$LOCK" 2>/dev/null || { echo "RESULT action=skip reason=no-lockfile"; exit 0; }
if ! flock -n 9; then
  echo "RESULT action=skip reason=already-running"
  exit 0
fi

NPROC=$(nproc 2>/dev/null || echo 1)
LOAD_CRIT=$(( NPROC * LOAD_CRIT_PER_CORE ))

# --- sample ---
read -r load1 _rest < /proc/loadavg
load1_int=${load1%%.*}; load1_int=${load1_int:-0}
mem_avail=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}'); mem_avail=${mem_avail:-99999}
swap_total=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}'); swap_total=${swap_total:-0}
swap_used=$(free -m 2>/dev/null | awk '/^Swap:/{print $3}'); swap_used=${swap_used:-0}
swap_pct=0
[ "$swap_total" -gt 0 ] 2>/dev/null && swap_pct=$(( swap_used * 100 / swap_total ))

# --- classify ---
level=ok
reasons=""
if [ "$load1_int" -ge "$LOAD_CRIT" ] 2>/dev/null; then level=critical; reasons="load1=${load1}>=${LOAD_CRIT}"; fi
if [ "$mem_avail" -lt "$MEM_CRIT_MB" ] 2>/dev/null; then level=critical; reasons="${reasons:+$reasons,}mem_avail=${mem_avail}MB<${MEM_CRIT_MB}"; fi
if [ "$swap_pct" -ge "$SWAP_CRIT_PCT" ] 2>/dev/null; then level=critical; reasons="${reasons:+$reasons,}swap=${swap_pct}%>=${SWAP_CRIT_PCT}"; fi

prev=$(cat "$STATE" 2>/dev/null || echo ok)
echo "$level" > "$STATE" 2>/dev/null || true

ts=$(date -u +%FT%TZ)
metrics="load1=${load1}(crit>=${LOAD_CRIT}) mem_avail=${mem_avail}MB swap=${swap_pct}%"
printf '%s level=%s prev=%s %s\n' "$ts" "$level" "$prev" "$metrics" >> "$LOG" 2>/dev/null || true

if [ "$level" != critical ]; then
  echo "RESULT action=none level=$level $metrics"
  exit 0
fi

# Debounce: act only when critical on two consecutive samples (avoids reacting
# to a momentary spike — a build kicking off, a backup, etc.).
if [ "$prev" != critical ]; then
  echo "RESULT action=observe level=critical-first-sample reasons=$reasons $metrics"
  exit 0
fi

# ---------------- remediate ----------------
actions=""

# 1. Shed the cause: kill runaway *build* tools. vite/esbuild/rollup are
#    build-only — no production container runs them at runtime — so this is
#    safe for prod. Bracket-guard each pattern (e.g. [e]sbuild) so pgrep/pkill
#    never matches this guard's own command line (the self-kill bug from the
#    2026-05-28 manual recovery).
build_pids=$(pgrep -f '[e]sbuild|[v]ite build|[r]ollup|[t]sc -b' 2>/dev/null || true)
if [ -n "$build_pids" ]; then
  echo "shedding build procs: $(echo "$build_pids" | tr '\n' ' ')" >> "$LOG" 2>/dev/null || true
  # shellcheck disable=SC2086
  kill -TERM $build_pids 2>/dev/null || true
  sleep 3
  still=$(pgrep -f '[e]sbuild|[v]ite build|[r]ollup|[t]sc -b' 2>/dev/null || true)
  # shellcheck disable=SC2086
  [ -n "$still" ] && kill -KILL $still 2>/dev/null || true
  actions="shed_builds"
fi

# 2. Protect the victim: if postgres is unhealthy/unreachable, restart it via
#    its compose labels (matches container-health.yml's remediation pattern).
health=$(docker inspect "$PG_CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo missing)
if [ "$health" != healthy ] && [ "$health" != missing ]; then
  wd=$(docker inspect "$PG_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || echo "")
  svc=$(docker inspect "$PG_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null || echo "")
  if [ -n "$wd" ] && [ -n "$svc" ]; then
    ( cd "$wd" && docker compose restart "$svc" ) >> "$LOG" 2>&1 || true
  else
    docker restart "$PG_CONTAINER" >> "$LOG" 2>&1 || true
  fi
  actions="${actions:+$actions,}restarted_postgres(was=$health)"
fi

[ -z "$actions" ] && actions="none_available"
printf '%s REMEDIATED action=%s reasons=%s %s\n' "$ts" "$actions" "$reasons" "$metrics" >> "$LOG" 2>/dev/null || true
echo "RESULT action=$actions level=critical reasons=$reasons $metrics"
