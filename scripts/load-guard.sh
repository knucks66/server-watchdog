#!/usr/bin/env bash
#
# Memory & Load Pressure Guard — engine (Layers 2 & 3, docs/load-guard-spec.md).
#
# Detects genuine memory/load pressure, debounces over two consecutive samples,
# then PROTECTS THE VICTIM: restarts postgres if it has gone unhealthy under
# pressure. Emits one machine-readable `RESULT ...` line for callers (the
# Layer 2 workflow parses it to alert).
#
# It deliberately does NOT kill build processes by default. The *cause* of the
# 2026-05-28 outage — runaway parallel `vite build`s — is contained
# structurally by Layer 1 (runners.slice MemoryMax), which OOM-kills a runaway
# build inside the runners' own cgroup before it can starve prod. A box-wide
# `pkill esbuild` is both redundant with that AND dangerous: esbuild is spawned
# by vitest and many other tools, so it kills innocent CI/test runs. An opt-in,
# tightly-scoped backstop is available via SHED_BUILDS=1 (see below).
#
# It DOES reap stale Actions workers (2026-08-16). That outage was invisible to
# every existing layer: three orphaned `Runner.Worker` processes ran `vite build`
# for 2h43m after GitHub had already given up on their jobs, thrashing the disk
# at ~1.4M blocks/s. Layer 1 never fired — the builds totalled ~5.3 GB, under the
# 7 GB cap, because the failure was I/O, not memory. runner-guard never fired —
# it restarts INACTIVE units, and these units were active. And this script logged
# `action=alert_only` every two minutes for hours, because load was critical while
# memory was fine and its only levers were memory-shaped.
#
# The reaper is scoped by AGE, not by process type, which is what makes it safe
# where SHED_BUILDS is not: a worker older than MAX_JOB_HOURS cannot be a healthy
# job (the longest real job on this box is ~50 min), so there is no innocent
# process in the target set. It also fires only after load has been critical for
# SUSTAINED_CRIT_SAMPLES consecutive samples, so a brief spike never triggers it.
#
# Runs identically from the on-box systemd timer (Layer 3) or piped over SSH by
# the GitHub workflow (Layer 2). A flock serializes the two cadences; a
# statefile carries the debounce across invocations. Must run as root.
#
# Tunables (env), defaults sized for the 8-core / ~15.6 GB Hetzner box:
#   LOAD_CRIT_PER_CORE (default 4)    critical when load1 >= cores * this
#   MEM_CRIT_MB        (default 600)  critical when MemAvailable below this
#   MEM_LOW_MB         (default 1500) "RAM getting low" — gates the swap signal
#   SWAP_CRIT_PCT      (default 90)   swap counts ONLY when also MemAvailable<MEM_LOW_MB
#   PG_CONTAINER       (default infrastructure-postgres-1)
#   SHED_BUILDS        (default 0)    if 1, also kill *deploy* builds in
#                                     runners.slice (vite build / npm run build),
#                                     never bare esbuild/vitest. Backstop only.
#   REAP_STALE_WORKERS (default 1)    reap Runner.Worker processes older than
#                                     MAX_JOB_HOURS once load has been critical
#                                     for SUSTAINED_CRIT_SAMPLES samples.
#   MAX_JOB_HOURS      (default 3)    a worker older than this is not a job any
#                                     more. Longest real job here is ~50 min, so
#                                     3h is >3x headroom.
#   SUSTAINED_CRIT_SAMPLES (default 10) consecutive critical samples before the
#                                     reaper is allowed to act (~20 min at the
#                                     2-minute timer cadence).
#
# Why swap is gated: after an OOM the kernel leaves pages in swap even once RAM
# is plentiful again. High swap% with healthy MemAvailable is stale, not
# pressure — treating it as critical caused a false positive in testing.

set -uo pipefail   # NOT -e: pgrep/grep return nonzero on "no match"; we handle it.

LOCK=/run/load-guard.lock
STATE=/run/load-guard.state      # last classification (ok|critical) for debounce
LOG=/var/log/load-guard.log

LOAD_CRIT_PER_CORE="${LOAD_CRIT_PER_CORE:-4}"
MEM_CRIT_MB="${MEM_CRIT_MB:-600}"
MEM_LOW_MB="${MEM_LOW_MB:-1500}"
SWAP_CRIT_PCT="${SWAP_CRIT_PCT:-90}"
PG_CONTAINER="${PG_CONTAINER:-infrastructure-postgres-1}"
SHED_BUILDS="${SHED_BUILDS:-0}"
REAP_STALE_WORKERS="${REAP_STALE_WORKERS:-1}"
MAX_JOB_HOURS="${MAX_JOB_HOURS:-3}"
SUSTAINED_CRIT_SAMPLES="${SUSTAINED_CRIT_SAMPLES:-10}"

# select_stale_workers <max_secs>
#
# Reads `ps -eo pid=,etimes=,args=` on stdin, emits "<pid>:<etimes>s" for every
# Actions worker older than <max_secs>. Pure: no side effects, no ps call — so
# tests/test-select-stale-workers.sh can drive it with fixtures. The dangerous
# half of the reaper is the SELECTION, so that is the half that is testable.
#
# Matches Runner.Worker ONLY. Not Runner.Listener (the long-lived supervisor —
# it is *always* older than any threshold and killing it takes the runner
# offline), and not the build processes themselves (a `vite build` may legitimately
# be minutes old under a healthy worker; the worker's own age is the honest
# signal for "this job is not a job any more").
select_stale_workers() {
  local max_secs="$1" pid etimes args
  while read -r pid etimes args; do
    [ -z "${pid:-}" ] && continue
    case "$args" in
      *Runner.Listener*) continue ;;
      *Runner.Worker*) ;;
      *) continue ;;
    esac
    case "$etimes" in (*[!0-9]*|"") continue ;; esac
    [ "$etimes" -gt "$max_secs" ] || continue
    printf '%s:%ss
' "$pid" "$etimes"
  done
}

# Optional: report to the Ownersbox dashboard so JARVIS gains awareness of
# load-guard activity (Layers 2 AND 3 share this engine). Interventions
# (anything other than a quiet healthy run) are pushed immediately; quiet
# healthy runs push a low-frequency *heartbeat* (action=heartbeat) at most once
# per OBX_HEARTBEAT_SECS so JARVIS has an independent liveness signal that
# survives GitHub deprioritizing the scheduled Layer-2 run. Purely additive and
# silently no-ops when the env vars are unset.
OBX_WEBHOOK_URL="${OBX_WEBHOOK_URL:-}"
OBX_TOKEN="${OBX_TOKEN:-}"
OBX_HEARTBEAT_SECS="${OBX_HEARTBEAT_SECS:-900}"   # 15 min
OBX_HB_STATE=/run/load-guard.obx-heartbeat

# emit RESULTLINE — always echo the machine-readable RESULT (callers parse it);
# then POST to Ownersbox per the intervention/heartbeat policy above. Best-effort.
emit() {
  local line="$1"
  echo "$line"
  [ -z "$OBX_WEBHOOK_URL" ] && return 0
  [ -z "$OBX_TOKEN" ] && return 0
  local lvl act rsn now raw_esc rsn_esc intervention last now_s
  lvl=$(printf '%s' "$line" | sed -n 's/.*level=\([^ ]*\).*/\1/p')
  act=$(printf '%s' "$line" | sed -n 's/.*action=\([^ ]*\).*/\1/p')
  rsn=$(printf '%s' "$line" | sed -n 's/.*reasons=\([^ ]*\).*/\1/p')
  case "$lvl" in critical*) lvl=critical ;; warn*) lvl=warn ;; *) lvl=ok ;; esac
  [ -z "$act" ] && act=none

  # Intervention = not a quiet healthy run. Those push immediately. A quiet
  # healthy run pushes a heartbeat only when one is due (throttled via statefile).
  intervention=0
  [ "$lvl" != ok ] && intervention=1
  case "$act" in none|observe|"") ;; *) intervention=1 ;; esac
  if [ "$intervention" != 1 ]; then
    last=$(cat "$OBX_HB_STATE" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0 ;; esac
    now_s=$(date +%s)
    [ $(( now_s - last )) -lt "$OBX_HEARTBEAT_SECS" ] && return 0   # heartbeat not due
    act=heartbeat
  fi
  date +%s > "$OBX_HB_STATE" 2>/dev/null || true   # any push is a sign of life

  now=$(date -u +%FT%TZ)
  raw_esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
  rsn_esc=$(printf '%s' "$rsn" | sed 's/\\/\\\\/g; s/"/\\"/g')
  curl -fsS -m 10 \
    -H "Authorization: Bearer ${OBX_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"layer\":\"load-guard\",\"level\":\"${lvl}\",\"action\":\"${act}\",\"reason\":\"${rsn_esc}\",\"raw\":\"${raw_esc}\",\"reported_at\":\"${now}\"}" \
    "$OBX_WEBHOOK_URL" >/dev/null 2>&1 || true
}

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

# --- classify (the real pressure signals are low MemAvailable and high load;
#     swap only counts when RAM is ALSO getting low) ---
level=ok
reasons=""
if [ "$load1_int" -ge "$LOAD_CRIT" ] 2>/dev/null; then
  level=critical; reasons="load1=${load1}>=${LOAD_CRIT}"
fi
if [ "$mem_avail" -lt "$MEM_CRIT_MB" ] 2>/dev/null; then
  level=critical; reasons="${reasons:+$reasons,}mem_avail=${mem_avail}MB<${MEM_CRIT_MB}"
fi
if [ "$swap_pct" -ge "$SWAP_CRIT_PCT" ] 2>/dev/null && [ "$mem_avail" -lt "$MEM_LOW_MB" ] 2>/dev/null; then
  level=critical; reasons="${reasons:+$reasons,}swap=${swap_pct}%>=${SWAP_CRIT_PCT}+mem_low"
fi

# Statefile carries "<level>:<consecutive-critical-count>". Older installs wrote
# a bare level, so parse defensively — a missing count reads as 0 and the reaper
# simply waits one more sample rather than misfiring on an unknown history.
state_raw=$(cat "$STATE" 2>/dev/null || echo ok)
prev="${state_raw%%:*}"
prev_crit_n="${state_raw#*:}"
case "$prev_crit_n" in (*[!0-9]*|"") prev_crit_n=0 ;; esac
[ "$prev" = critical ] || prev_crit_n=0

if [ "$level" = critical ]; then
  crit_n=$(( prev_crit_n + 1 ))
else
  crit_n=0
fi
echo "${level}:${crit_n}" > "$STATE" 2>/dev/null || true

ts=$(date -u +%FT%TZ)
metrics="load1=${load1}(crit>=${LOAD_CRIT}) mem_avail=${mem_avail}MB swap=${swap_pct}% crit_n=${crit_n}"
printf '%s level=%s prev=%s %s\n' "$ts" "$level" "$prev" "$metrics" >> "$LOG" 2>/dev/null || true

if [ "$level" != critical ]; then
  emit "RESULT action=none level=$level $metrics"
  exit 0
fi

# Debounce: act only when critical on two consecutive samples.
if [ "$prev" != critical ]; then
  emit "RESULT action=observe level=critical-first-sample reasons=$reasons $metrics"
  exit 0
fi

# ---------------- remediate ----------------
actions=""

# Optional backstop: shed *deploy* builds, scoped to the runners' cgroup and
# matched to `vite build` / `npm run build` only — NEVER bare esbuild or vitest
# (those are also CI/test). Off by default; Layer 1 already contains runaway
# builds, so this is a belt-and-suspenders escape hatch.
if [ "$SHED_BUILDS" = "1" ]; then
  slice_cg=/sys/fs/cgroup/runners.slice/cgroup.procs
  killed=""
  if [ -r "$slice_cg" ]; then
    # Collect all PIDs anywhere under runners.slice.
    mapfile -t slice_pids < <(find /sys/fs/cgroup/runners.slice -name cgroup.procs -exec cat {} \; 2>/dev/null | sort -u)
    for pid in "${slice_pids[@]}"; do
      [ -z "$pid" ] && continue
      cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
      case "$cmd" in
        *"vite build"*|*"npm run build"*|*"astro build"*)
          kill -TERM "$pid" 2>/dev/null && killed="${killed} $pid" ;;
      esac
    done
  fi
  [ -n "$killed" ] && { sleep 3; for p in $killed; do kill -KILL "$p" 2>/dev/null || true; done; actions="shed_builds(${killed# })"; }
fi

# Reap STALE Actions workers. Scoped by AGE, which is what makes this safe to
# have on by default where SHED_BUILDS is not: the longest legitimate job on this
# box is ~50 min, so anything past MAX_JOB_HOURS is not a job any more — it is an
# orphan whose GitHub-side job is already gone. Killing it frees the box; leaving
# it wedges CI indefinitely, because a saturated box stops the runners
# heartbeating, GitHub marks them offline, queued jobs never dispatch, and
# nothing then exists to clear the orphan. That deadlock is the 2026-08-16
# outage, and it is self-sustaining: it does not resolve on its own.
#
# Gated on SUSTAINED critical rather than the 2-sample debounce the other actions
# use. A long build legitimately drives load up; only load that STAYS critical
# for ~20 minutes alongside an over-age worker indicates the wedge.
if [ "$REAP_STALE_WORKERS" = "1" ] && [ "$crit_n" -ge "$SUSTAINED_CRIT_SAMPLES" ] 2>/dev/null; then
  max_job_secs=$(( MAX_JOB_HOURS * 3600 ))
  reaped=""
  for entry in $(ps -eo pid=,etimes=,args= 2>/dev/null | select_stale_workers "$max_job_secs"); do
    rpid="${entry%%:*}"
    # Children first: vite/esbuild reparent to init and survive if the worker
    # dies before them.
    pkill -TERM -P "$rpid" 2>/dev/null
    kill -TERM "$rpid" 2>/dev/null
    reaped="${reaped} ${entry}"
  done

  if [ -n "$reaped" ]; then
    sleep 5
    for entry in $reaped; do
      rp="${entry%%:*}"
      pkill -KILL -P "$rp" 2>/dev/null
      kill -KILL "$rp" 2>/dev/null
    done
    # A worker killed mid-job leaves its runner listener confused; restart the
    # units so they re-register cleanly and start taking work again.
    systemctl restart 'actions.runner.*' >> "$LOG" 2>&1 || true
    actions="${actions:+$actions,}reaped_stale_workers(${reaped# })"
  fi
fi

# Protect the victim: if postgres is unhealthy, restart it via compose labels
# (matches container-health.yml). This is the safe, always-on remediation.
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

[ -z "$actions" ] && actions="alert_only"
printf '%s CRITICAL action=%s reasons=%s %s\n' "$ts" "$actions" "$reasons" "$metrics" >> "$LOG" 2>/dev/null || true
emit "RESULT action=$actions level=critical reasons=$reasons $metrics"
