#!/usr/bin/env bash
#
# Resource Monitor & Cleanup — the shared engine.
#
# Watches disk, RAM, swap and zombie processes; reclaims disk when it crosses
# the critical threshold; removes containers orphaned by a deleted compose file.
#
# Emits one machine-readable `RESULT ...` line, which callers parse.
#
# Layer 2 (resource-monitor.yml) pipes THIS file to the box over SSH; Layer 3
# runs the installed copy from a systemd timer every 2 hours. A flock serializes
# the two cadences. Layer 3 is the primary path because it needs no external
# service — GitHub was delivering this workflow's 2-hourly cron roughly 7 times
# a day in total across all seven watchdog workflows.
#
# Every destructive action honours DRY_RUN=1, which reports what it would do and
# changes nothing. Use it for the first run on a new box.
set -uo pipefail   # NOT -e: ps/grep/docker return nonzero on "no match".

LOCK=/run/resource-monitor.lock
LOG=/var/log/resource-monitor.log

DISK_CRIT_PCT="${DISK_CRIT_PCT:-85}"
DISK_WARN_PCT="${DISK_WARN_PCT:-70}"
MEM_LOW_MB="${MEM_LOW_MB:-300}"
SWAP_CRIT_PCT="${SWAP_CRIT_PCT:-80}"
ZOMBIE_CRIT="${ZOMBIE_CRIT:-100}"
ZOMBIE_PER_PARENT_MIN="${ZOMBIE_PER_PARENT_MIN:-10}"
BUILDER_KEEP="${BUILDER_KEEP:-2GB}"
DRY_RUN="${DRY_RUN:-0}"

OBX_WEBHOOK_URL="${OBX_WEBHOOK_URL:-}"
OBX_TOKEN="${OBX_TOKEN:-}"

# ── pure decision helpers ────────────────────────────────────────────────────
# Extracted verbatim by tests/test-resource-monitor.sh. Side-effect free: this
# is the half that DECIDES, and this script deletes volumes and removes
# containers.

# is_anonymous_volume <name> -> 0 if Docker generated it, 1 if a human named it.
#
# THE most important predicate in this file. `docker volume prune -f` deletes
# every unreferenced volume, NAMED ones included. A named volume is data
# somebody deliberately created, and a detached one is usually a service that is
# temporarily down or was moved between compose files — not garbage. On
# 2026-08-05 this box had 133 unreferenced volumes and five were named,
# including `podcastwiz_postgres-data`, a live Postgres data directory. Disk sat
# at 81%; had it crossed 85% a blanket prune would have destroyed that database
# with no prompt and no backup.
#
# Anonymous volumes are exactly 64 lowercase hex characters — the IDs Docker
# invents for unnamed VOLUME directives and abandons on every container
# recreate. Those were 128 of the 133 and are the actual churn.
is_anonymous_volume() {
  case "${1:-}" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 64 ]
}

# disk_action <pct> -> prints cleanup | monitor | ok
disk_action() {
  local pct="${1:-0}"
  case "$pct" in ''|*[!0-9]*) echo ok; return ;; esac
  if [ "$pct" -ge "$DISK_CRIT_PCT" ]; then echo cleanup
  elif [ "$pct" -ge "$DISK_WARN_PCT" ]; then echo monitor
  else echo ok; fi
}

# parent_qualifies <zombie_count> -> 0 if this parent is worth restarting.
# A handful of zombies is normal reaping lag; a container leaking them produces
# dozens, and restarting for two would churn healthy services.
parent_qualifies() {
  local n="${1:-0}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -ge "$ZOMBIE_PER_PARENT_MIN" ]
}

# ── reporting ────────────────────────────────────────────────────────────────
emit() {
  local line="$1"
  echo "$line"
  [ -z "$OBX_WEBHOOK_URL" ] && return 0
  [ -z "$OBX_TOKEN" ] && return 0
  local lvl act rsn payload
  lvl=$(printf '%s' "$line" | sed -n 's/.*level=\([^ ]*\).*/\1/p')
  act=$(printf '%s' "$line" | sed -n 's/.*action=\([^ ]*\).*/\1/p')
  rsn=$(printf '%s' "$line" | sed -n 's/.*reasons=\(.*\)$/\1/p')
  case "$lvl" in critical*) lvl=critical ;; warn*) lvl=warn ;; *) lvl=ok ;; esac
  [ -z "$act" ] && act=none
  payload=$(printf '{"source":"resource-monitor","level":"%s","action":"%s","detail":"%s"}' \
            "$lvl" "$act" "$(printf '%s' "$rsn" | sed 's/\\/\\\\/g; s/"/\\"/g')")
  curl -s --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${OBX_TOKEN}" \
    -d "$payload" \
    "$OBX_WEBHOOK_URL" >/dev/null 2>&1 || true
}

run() {   # run <description> <command...>
  local what="$1"; shift
  if [ "$DRY_RUN" = "1" ]; then echo "  DRY_RUN: would $what"; return 0; fi
  echo "  $what"
  "$@" 2>&1 | tail -3
}

# Sourcing (as the tests do) must not delete anything.
case "${BASH_SOURCE[0]}" in "$0") ;; *) return 0 2>/dev/null || true ;; esac

exec 9>"$LOCK" 2>/dev/null || { echo "RESULT action=skip level=ok reasons=no-lockfile"; exit 0; }
flock -n 9 || { echo "RESULT action=skip level=ok reasons=another-run-holds-the-lock"; exit 0; }

problems=()
actions=()

# ── disk ─────────────────────────────────────────────────────────────────────
DISK_PCT=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
case "$DISK_PCT" in ''|*[!0-9]*) DISK_PCT=0 ;; esac
DISK_AVAIL=$(df -h / --output=avail 2>/dev/null | tail -1 | tr -d ' ')
DISK_VERDICT=$(disk_action "$DISK_PCT")
echo "Disk: ${DISK_PCT}% used (${DISK_AVAIL:-unknown} available) -> $DISK_VERDICT"
[ "$DISK_VERDICT" = monitor ] && problems+=("disk-elevated(${DISK_PCT}%)")
[ "$DISK_VERDICT" = cleanup ] && problems+=("disk-critical(${DISK_PCT}%)")

# ── memory and swap (observed, never acted on here) ──────────────────────────
# Shedding load under memory pressure is load-guard.sh's job, on a 2-minute
# cadence. Duplicating it here on a 2-hour one would fight it.
MEM_AVAIL=$(free -m 2>/dev/null | awk '/Mem:/ {print $7}')
SWAP_TOTAL=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}')
SWAP_USED=$(free -m 2>/dev/null | awk '/Swap:/ {print $3}')
case "$MEM_AVAIL" in ''|*[!0-9]*) MEM_AVAIL=0 ;; esac
case "$SWAP_TOTAL" in ''|*[!0-9]*) SWAP_TOTAL=0 ;; esac
case "$SWAP_USED" in ''|*[!0-9]*) SWAP_USED=0 ;; esac
echo "RAM available: ${MEM_AVAIL}MB; swap ${SWAP_USED}/${SWAP_TOTAL}MB"
[ "$MEM_AVAIL" -lt "$MEM_LOW_MB" ] && problems+=("ram-low(${MEM_AVAIL}MB)")
if [ "$SWAP_TOTAL" -gt 0 ]; then
  SWAP_PCT=$(( SWAP_USED * 100 / SWAP_TOTAL ))
  [ "$SWAP_PCT" -ge "$SWAP_CRIT_PCT" ] && problems+=("swap-high(${SWAP_PCT}%)")
fi

# ── zombies ──────────────────────────────────────────────────────────────────
ZOMBIES=$(ps -eo stat 2>/dev/null | grep -c Z)
case "$ZOMBIES" in ''|*[!0-9]*) ZOMBIES=0 ;; esac
echo "Zombie processes: $ZOMBIES"
if [ "$ZOMBIES" -gt "$ZOMBIE_CRIT" ]; then
  problems+=("zombies($ZOMBIES)")
  ps -eo ppid,stat 2>/dev/null | awk '$2 ~ /Z/ {print $1}' | sort | uniq -c | sort -rn | head -5 \
  | while read -r count ppid; do
      [ -z "$ppid" ] && continue
      parent_qualifies "$count" || continue
      CGROUP=$(head -1 "/proc/$ppid/cgroup" 2>/dev/null || echo "")
      CID=$(printf '%s' "$CGROUP" | grep -o '[a-f0-9]\{64\}' | head -1)
      if [ -z "$CID" ]; then
        echo "  PID $ppid ($count zombies) is not in a container — skipping"
        continue
      fi
      SHORT=${CID:0:12}
      WORKDIR=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$SHORT" 2>/dev/null || echo "")
      SERVICE=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.service"}}' "$SHORT" 2>/dev/null || echo "")
      if [ -n "$WORKDIR" ] && [ -n "$SERVICE" ]; then
        if [ "$DRY_RUN" = "1" ]; then
          echo "  DRY_RUN: would compose-restart $SERVICE in $WORKDIR ($count zombies)"
        else
          echo "  compose-restart $SERVICE ($count zombies)"
          ( cd "$WORKDIR" && docker compose restart "$SERVICE" ) 2>&1 | tail -2
        fi
      else
        run "restart $SHORT ($count zombies)" docker restart "$SHORT"
      fi
    done
  actions+=(zombie-parents-restarted)
fi

# ── orphan containers ────────────────────────────────────────────────────────
# A running container whose compose file no longer exists: left behind when a
# project was deleted or moved, holding ports, memory and disk that nothing
# will ever reclaim.
ORPHANS=""
for container in $(docker ps --format '{{.Names}}' 2>/dev/null); do
  CONFIG=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container" 2>/dev/null || echo "")
  [ -z "$CONFIG" ] && continue
  [ -f "$CONFIG" ] && continue
  echo "  orphan: $container (compose file missing: $CONFIG)"
  ORPHANS="$ORPHANS $container"
done
ORPHANS=$(printf '%s' "$ORPHANS" | xargs || true)
if [ -n "$ORPHANS" ]; then
  problems+=("orphans($ORPHANS)")
  for container in $ORPHANS; do
    if [ "$DRY_RUN" = "1" ]; then
      echo "  DRY_RUN: would stop and remove $container"
    else
      docker stop "$container" >/dev/null 2>&1 && docker rm "$container" >/dev/null 2>&1 \
        && echo "  removed $container" || echo "  could not remove $container"
    fi
  done
  actions+=(orphans-removed)
fi

# ── reclaim disk, only when critical ─────────────────────────────────────────
if [ "$DISK_VERDICT" = cleanup ]; then
  echo "Disk critical — reclaiming"
  run "prune dangling images" docker image prune -f
  run "prune build cache (keeping $BUILDER_KEEP)" docker builder prune -f --keep-storage="$BUILDER_KEEP"

  # Anonymous volumes only. See is_anonymous_volume above for why a blanket
  # `docker volume prune` is not acceptable here.
  anon=0; named=""
  while IFS= read -r vol; do
    [ -z "$vol" ] && continue
    if is_anonymous_volume "$vol"; then
      anon=$(( anon + 1 ))
      [ "$DRY_RUN" = "1" ] || docker volume rm "$vol" >/dev/null 2>&1 || true
    else
      named="$named $vol"
    fi
  done <<< "$(docker volume ls -qf dangling=true 2>/dev/null || true)"
  if [ "$DRY_RUN" = "1" ]; then
    echo "  DRY_RUN: would remove $anon anonymous volume(s)"
  else
    echo "  removed $anon anonymous volume(s)"
  fi

  # Named orphans get a human decision rather than silent deletion or silence.
  if [ -n "$named" ]; then
    echo "  named volumes unreferenced but NOT deleted (review manually):"
    for v in $named; do echo "    $v"; done
    problems+=("named-volumes-unreferenced($(printf '%s' "$named" | xargs))")
  fi

  NEW_PCT=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
  echo "  disk after cleanup: ${NEW_PCT}%"
  actions+=("disk-reclaimed(${DISK_PCT}%->${NEW_PCT}%)")
fi

# ── result ───────────────────────────────────────────────────────────────────
level=ok; action=none
[ "${#problems[@]}" -gt 0 ] && level=warn
[ "$DISK_VERDICT" = cleanup ] && level=critical
[ "${#actions[@]}" -gt 0 ] && action="$(printf '%s,' "${actions[@]}" | sed 's/,$//')"
reasons="${problems[*]:-none}"
[ "$DRY_RUN" = "1" ] && action="dry-run"

ts=$(date -Is)
printf '%s level=%s action=%s reasons=%s\n' "$ts" "$level" "$action" "$reasons" >> "$LOG" 2>/dev/null || true
emit "RESULT action=$action level=$level reasons=$reasons"
