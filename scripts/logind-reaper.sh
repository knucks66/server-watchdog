#!/usr/bin/env bash
#
# systemd-logind leaked-session reaper — engine (docs/logind-reaper-spec.md).
#
# systemd 255 on this host leaks sessions stuck in State=closing with Leader=0
# (the leader process is long dead) that logind never reaps. Each holds an
# anon_inode:[pidfd] fd in logind's process. They accumulate until logind hits
# 8192 open fds = the login ceiling, after which new logins / `docker exec`
# start failing. This is the known systemd 255 logind bug; it is NOT fixable by
# upgrade (host is already on the latest noble patch) and the config knobs
# (KillUserProcesses / StopIdleSessionSec / UserStopDelaySec) don't help because
# the stuck sessions have no processes left to kill.
#
# This engine DETECTS the buildup, REMEDIATES it, and REPORTS the action up to
# JARVIS via the existing Ownersbox bridge so the leak is never silent again.
#
# Detection (read-only): logind's open fd count (the direct danger metric) and
# the count of sessions stuck closing with a dead leader (the leaked ones).
#
# Remediation (escalating, at most one action per run, cooldown-guarded):
#   1. Surgical: `loginctl terminate-session <id>` for each leaked session.
#      On systemd 255 this frequently does NOT clear a Leader=0 closing session
#      (that's the bug) — so we re-read the fd count and escalate if it didn't
#      drop.
#   2. Reliable: `systemctl restart systemd-logind`. Proven safe on this host
#      (2026-06-16): active SSH sessions survive, Docker containers are
#      untouched, only the leaked session state is dropped (fds 8,213 -> 21).
#      This is the primary action past FD_RESTART and the fallback when step 1
#      doesn't bring the count down.
#
# Runs identically from the on-box systemd timer (Layer 3) or piped over SSH by
# the GitHub workflow (Layer 2). A flock serializes the two cadences; a
# cooldown statefile prevents a flapping count from loop-restarting logind.
# Must run as root (to read /proc/<logind-pid>/fd and to restart logind).
#
# Tunables (env), sized with a huge margin under the 8192 login ceiling:
#   FD_WARN     (default 1000) warn-only report at/above this fd count
#   FD_ACT      (default 2000) act (surgical first) at/above this fd count
#   FD_RESTART  (default 4000) skip straight to restarting logind at/above this
#   LEAKED_ACT  (default 200)  act when this many leaked sessions are counted
#   COOLDOWN_SECS (default 1800) min seconds between remediations (anti-flap)
#
# Why these thresholds: 8192 took ~75 days to fill (mostly a CI burst); 2000
# still leaves weeks of headroom and fires long before any login can break.

set -uo pipefail   # NOT -e: loginctl/grep return nonzero on "no match"; we handle it.

LOCK=/run/logind-reaper.lock
COOLDOWN=/run/logind-reaper.cooldown   # epoch secs of last remediation (anti-flap)
LOG=/var/log/logind-reaper.log

FD_WARN="${FD_WARN:-1000}"
FD_ACT="${FD_ACT:-2000}"
FD_RESTART="${FD_RESTART:-4000}"
LEAKED_ACT="${LEAKED_ACT:-200}"
COOLDOWN_SECS="${COOLDOWN_SECS:-1800}"

# Optional: report to the Ownersbox dashboard so JARVIS gains awareness of any
# reap (Layers 2 AND 3 share this engine). Policy is "push interventions only":
# a reap or an un-actable critical is pushed immediately; quiet ok/warn runs are
# NOT pushed (warn state-change alerting is handled by the Layer 2 Discord path,
# and liveness by load-guard's heartbeat + the pulled GitHub run status — a
# third heartbeat stream here would just be noise). Silently no-ops when the
# env vars are unset.
OBX_WEBHOOK_URL="${OBX_WEBHOOK_URL:-}"
OBX_TOKEN="${OBX_TOKEN:-}"

# emit RESULTLINE LEVEL ACTION REASON — always echo the machine-readable RESULT
# (callers parse it), then POST to Ownersbox when this run is an intervention.
# Best-effort: never fails the run.
emit() {
  local line="$1" lvl="$2" act="$3" rsn="$4"
  echo "$line"
  [ -z "$OBX_WEBHOOK_URL" ] && return 0
  [ -z "$OBX_TOKEN" ] && return 0

  # Intervention = an action was performed, or a critical we could not clear.
  # Quiet ok/warn runs don't push (see policy note above).
  case "$act" in
    terminate_sessions*|restarted_logind*) ;;                 # acted -> push
    *) [ "$lvl" = critical ] || return 0 ;;                   # critical -> push, else skip
  esac

  local now raw_esc rsn_esc
  now=$(date -u +%FT%TZ)
  raw_esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
  rsn_esc=$(printf '%s' "$rsn"  | sed 's/\\/\\\\/g; s/"/\\"/g')
  curl -fsS -m 10 \
    -H "Authorization: Bearer ${OBX_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"layer\":\"logind-reaper\",\"level\":\"${lvl}\",\"action\":\"${act}\",\"target\":\"logind\",\"reason\":\"${rsn_esc}\",\"raw\":\"${raw_esc}\",\"reported_at\":\"${now}\"}" \
    "$OBX_WEBHOOK_URL" >/dev/null 2>&1 || true
}

exec 9>"$LOCK" 2>/dev/null || { echo "RESULT action=skip level=ok reason=no-lockfile"; exit 0; }
if ! flock -n 9; then
  echo "RESULT action=skip level=ok reason=already-running"
  exit 0
fi

# --- locate logind & read the danger metric (open fd count) ---
LPID=$(systemctl show -p MainPID --value systemd-logind 2>/dev/null || echo 0)
case "$LPID" in ''|*[!0-9]*) LPID=0 ;; esac
if [ "$LPID" = 0 ]; then
  emit "RESULT action=skip level=ok reason=no-logind" ok skip no-logind
  exit 0
fi

# count_fds <pid> — number of open fds held by that pid (0 if unreadable)
count_fds() {
  local n
  n=$(ls -1 /proc/"$1"/fd 2>/dev/null | wc -l)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}

FDS=$(count_fds "$LPID")

# --- count the leaked sessions (closing + dead leader) and collect their ids.
#     The strict "closing AND Leader=0" gate is also the safety gate: we will
#     only ever terminate these, never an active/online login. ---
LEAKED_IDS=""
for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
  [ -z "$s" ] && continue
  st=$(loginctl show-session "$s" -p State  --value 2>/dev/null)
  ld=$(loginctl show-session "$s" -p Leader --value 2>/dev/null)
  if [ "$st" = closing ] && [ "$ld" = 0 ]; then
    LEAKED_IDS="${LEAKED_IDS:+$LEAKED_IDS }$s"
  fi
done
LEAKED=0
[ -n "$LEAKED_IDS" ] && LEAKED=$(printf '%s\n' $LEAKED_IDS | wc -l)

# --- classify ---
level=ok
reasons=""
if [ "$FDS" -ge "$FD_RESTART" ] 2>/dev/null; then
  level=critical; reasons="fds=${FDS}>=${FD_RESTART}"
elif [ "$FDS" -ge "$FD_ACT" ] 2>/dev/null || [ "$LEAKED" -ge "$LEAKED_ACT" ] 2>/dev/null; then
  level=critical
  [ "$FDS" -ge "$FD_ACT" ] 2>/dev/null && reasons="fds=${FDS}>=${FD_ACT}"
  [ "$LEAKED" -ge "$LEAKED_ACT" ] 2>/dev/null && reasons="${reasons:+$reasons,}leaked=${LEAKED}>=${LEAKED_ACT}"
elif [ "$FDS" -ge "$FD_WARN" ] 2>/dev/null; then
  level=warn; reasons="fds=${FDS}>=${FD_WARN}"
fi

ts=$(date -u +%FT%TZ)
metrics="logind_fds=${FDS} leaked=${LEAKED}"
printf '%s level=%s %s\n' "$ts" "$level" "$metrics" >> "$LOG" 2>/dev/null || true

if [ "$level" != critical ]; then
  emit "RESULT action=none level=$level $metrics" "$level" none "${reasons:-none}"
  exit 0
fi

# --- critical: remediate, but honor the cooldown so a stuck count can't
#     loop-restart logind across back-to-back ticks (Layer 2 + Layer 3 share
#     this statefile via the flock). ---
now_s=$(date +%s)
last=$(cat "$COOLDOWN" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0 ;; esac
if [ $(( now_s - last )) -lt "$COOLDOWN_SECS" ]; then
  emit "RESULT action=cooldown level=critical reasons=$reasons $metrics" \
    critical cooldown "in cooldown (${reasons}); fds=${FDS} leaked=${LEAKED}"
  exit 0
fi

action=""
restart_logind() {
  systemctl restart systemd-logind >> "$LOG" 2>&1 || true
}

if [ "$FDS" -ge "$FD_RESTART" ] 2>/dev/null; then
  # Past the high-water mark: skip the surgical step (it usually doesn't clear
  # the bug) and go straight to the reliable clear.
  restart_logind
  action="restarted_logind"
else
  # Surgical first — least aggressive. Only ever targets the closing+Leader=0
  # ids collected above (never a live session).
  for s in $LEAKED_IDS; do
    loginctl terminate-session "$s" >> "$LOG" 2>&1 || true
  done
  sleep 2
  FDS_AFTER_TERM=$(count_fds "$LPID")
  if [ "$FDS_AFTER_TERM" -ge "$FD_ACT" ] 2>/dev/null; then
    # terminate-session didn't bring it down (the systemd 255 bug) — escalate.
    restart_logind
    action="restarted_logind"
  else
    action="terminate_sessions(${LEAKED})"
  fi
fi

date +%s > "$COOLDOWN" 2>/dev/null || true

# Re-read for the before -> after report. Re-resolve the pid first: a logind
# restart gives it a NEW MainPID, so the original /proc/<pid>/fd is gone.
sleep 1
LPID_NOW=$(systemctl show -p MainPID --value systemd-logind 2>/dev/null || echo 0)
case "$LPID_NOW" in ''|*[!0-9]*) LPID_NOW=0 ;; esac
FDS_NOW=0
[ "$LPID_NOW" != 0 ] && FDS_NOW=$(count_fds "$LPID_NOW")
human="${action%%(*}: fds ${FDS}->${FDS_NOW}, leaked was ${LEAKED} (${reasons})"
printf '%s ACTED action=%s reasons=%s %s -> logind_fds=%s\n' \
  "$ts" "$action" "$reasons" "$metrics" "$FDS_NOW" >> "$LOG" 2>/dev/null || true
emit "RESULT action=$action level=critical reasons=$reasons logind_fds=${FDS}->${FDS_NOW} leaked=${LEAKED}" \
  critical "$action" "$human"
