#!/usr/bin/env bash
#
# Self-hosted GitHub Actions Runner Guard — engine (Layers 2 & 3).
#
# Checks all actions.runner.* systemd units on the box:
#   1. systemctl is-active for each runner service
#   2. Restart any that are inactive/failed
#   3. Per-runner cooldown prevents restart loops
#   4. Report interventions to Ownersbox via the watchdog event webhook
#
# Runs identically from the on-box systemd timer (Layer 3) or piped over SSH by
# the GitHub workflow (Layer 2). A flock serializes the two cadences; a
# statefile carries per-runner cooldown across invocations. Must run as root.
#
# The on-box timer (Layer 3) is the PRIMARY recovery path — it survives even
# when ALL runners are down and GitHub Actions can't fire the Layer 2 workflow.
# This is the same circular-dependency protection that load-guard and
# logind-reaper already rely on for their own Layer 3 timers.
#
# Tunables (env):
#   RUNNER_RESTART_COOLDOWN_SECS (default 600) min seconds between restarts of same runner
#   OBX_WEBHOOK_URL / OBX_TOKEN  — Ownersbox push creds (inherited from load-guard.env)
#   OBX_HEARTBEAT_SECS           — heartbeat cadence in seconds (default 900 = 15 min)

set -uo pipefail

LOCK=/run/runner-guard.lock
STATE=/run/runner-guard.state       # per-runner cooldown: "runner_name=epoch_sec"
LOG=/var/log/runner-guard.log

RUNNER_RESTART_COOLDOWN_SECS="${RUNNER_RESTART_COOLDOWN_SECS:-600}"

OBX_WEBHOOK_URL="${OBX_WEBHOOK_URL:-}"
OBX_TOKEN="${OBX_TOKEN:-}"
OBX_HEARTBEAT_SECS="${OBX_HEARTBEAT_SECS:-900}"
OBX_HB_STATE=/run/runner-guard.obx-heartbeat

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

  # Intervention = not a quiet healthy run → push immediately.
  # A quiet healthy run pushes a heartbeat only when one is due (throttled).
  intervention=0
  [ "$lvl" != ok ] && intervention=1
  case "$act" in none|"") ;; *) intervention=1 ;; esac
  if [ "$intervention" != 1 ]; then
    last=$(cat "$OBX_HB_STATE" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0 ;; esac
    now_s=$(date +%s)
    [ $(( now_s - last )) -lt "$OBX_HEARTBEAT_SECS" ] && return 0
    act=heartbeat
  fi
  date +%s > "$OBX_HB_STATE" 2>/dev/null || true

  now=$(date -u +%FT%TZ)
  raw_esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
  rsn_esc=$(printf '%s' "$rsn" | sed 's/\\/\\\\/g; s/"/\\"/g')
  curl -fsS -m 10 \
    -H "Authorization: Bearer ${OBX_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"layer\":\"runner-guard\",\"level\":\"${lvl}\",\"action\":\"${act}\",\"target\":\"runner\",\"reason\":\"${rsn_esc}\",\"raw\":\"${raw_esc}\",\"reported_at\":\"${now}\"}" \
    "$OBX_WEBHOOK_URL" >/dev/null 2>&1 || true
}

exec 9>"$LOCK" 2>/dev/null || { echo "RESULT action=skip level=ok reason=no-lockfile"; exit 0; }
if ! flock -n 9; then
  echo "RESULT action=skip level=ok reason=already-running"
  exit 0
fi

# Utility: read cooldown state for a given runner; returns epoch seconds or 0.
read_cooldown() {
  local runner="$1" val
  val=$(grep "^${runner}=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2)
  case "$val" in ''|*[!0-9]*) echo 0 ;; *) echo "$val" ;; esac
}

# Utility: write cooldown state for a given runner.
write_cooldown() {
  local runner="$1" epoch="$2"
  grep -v "^${runner}=" "$STATE" 2>/dev/null > "${STATE}.tmp" || true
  printf '%s=%s\n' "$runner" "$epoch" >> "${STATE}.tmp"
  mv "${STATE}.tmp" "$STATE"
}

# --- Discover all actions.runner.* units ---
mapfile -t UNITS < <(
  systemctl list-units 'actions.runner.*' --all --no-legend --plain 2>/dev/null \
    | awk '{print $1, $2}'   # unit name + active state
)

if [ "${#UNITS[@]}" -eq 0 ]; then
  emit "RESULT action=none level=ok reason=no-runners"
  exit 0
fi

ts=$(date -u +%FT%TZ)
acted=0
total=0
problems=()
fixes=()

for entry in "${UNITS[@]}"; do
  unit=$(echo "$entry" | awk '{print $1}')
  state=$(echo "$entry" | awk '{print $2}')
  [ -z "$unit" ] && continue
  total=$(( total + 1 ))

  # Extract runner name: actions.runner.<name>.service -> <name>
  runner_name="${unit#actions.runner.}"
  runner_name="${runner_name%.service}"

  # If the unit is active, nothing to do.
  if [ "$state" = active ]; then
    continue
  fi

  # Unit is not active — check cooldown.
  now_s=$(date +%s)
  last_restart=$(read_cooldown "$runner_name")
  if [ "$last_restart" -ne 0 ] && [ $(( now_s - last_restart )) -lt "$RUNNER_RESTART_COOLDOWN_SECS" ]; then
    problems+=("${runner_name}(cooldown)")
    continue
  fi

  problems+=("${runner_name}(${state})")

  # Attempt restart.
  if systemctl restart "$unit" 2>> "$LOG"; then
    write_cooldown "$runner_name" "$now_s"
    fixes+=("${runner_name}")
    acted=$(( acted + 1 ))
    printf '%s RESTARTED unit=%s state=%s\n' "$ts" "$unit" "$state" >> "$LOG" 2>/dev/null || true
  else
    printf '%s FAILED unit=%s state=%s\n' "$ts" "$unit" "$state" >> "$LOG" 2>/dev/null || true
    fixes+=("${runner_name}(restart-failed)")
  fi
done

# --- Build result line ---
level=ok
action=none
reasons=""
if [ "$acted" -gt 0 ]; then
  level=warn
  action="restarted(${acted}/${total})"
  reasons="restarted: ${fixes[*]}"
fi
if [ "${#problems[@]}" -gt 0 ]; then
  [ "$acted" -eq 0 ] && level=critical
  reasons="${reasons:+$reasons }problem: ${problems[*]}"
fi

metrics="runners_total=${total} acted=${acted}"
printf '%s level=%s action=%s reasons=%s %s\n' \
  "$ts" "$level" "$action" "$reasons" "$metrics" >> "$LOG" 2>/dev/null || true
emit "RESULT action=$action level=$level reasons=$reasons $metrics"
