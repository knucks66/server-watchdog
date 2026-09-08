#!/usr/bin/env bash
#
# Container Health & Dependency Check — the shared engine.
#
# Detects containers that are RUNNING but broken, and restarts them:
#   - SuperTokens / Hasura alive but having lost their Postgres connection
#   - dependents started BEFORE Postgres was recreated (they hold dead pools)
#   - Wyze Bridge hard-down, or HTTP-200 while its cloud Events subscription
#     has silently drifted and stopped delivering motion
#   - anything Docker itself reports as health=unhealthy
#
# Emits one machine-readable `RESULT ...` line, which callers parse.
#
# Layer 2 (container-health.yml) pipes THIS file to the box over SSH; Layer 3
# runs the installed copy from a systemd timer every 10 minutes. A flock
# serializes the two cadences. Layer 3 is the primary path because it needs no
# external service — which is what keeps recovery working when GitHub's
# scheduler drops runs, as it does: a 10-minute cron was being delivered roughly
# 7 times a day, with gaps over four hours.
#
# Extracting this from the workflow also removed ~15 separate SSH round-trips
# per run, each of which was a fail2ban risk the workflow itself warns about.
#
# Every action honours DRY_RUN=1, which reports what it would do and changes
# nothing. Use it for the first run on a new box.
set -uo pipefail   # NOT -e: curl/docker return nonzero on the conditions we handle.

LOCK=/run/container-health.lock
LOG=/var/log/container-health.log

PG_CONTAINER="${PG_CONTAINER:-infrastructure-postgres-1}"
PG_DEPENDENTS="${PG_DEPENDENTS:-infrastructure-supertokens-1 infrastructure-hasura-1}"
SUPERTOKENS_URL="${SUPERTOKENS_URL:-http://localhost:3567}"
HASURA_URL="${HASURA_URL:-http://localhost:8080}"
WYZE_URL="${WYZE_URL:-http://localhost:5050}"
WYZE_CONTAINER="${WYZE_CONTAINER:-wyze-bridge}"
WYZE_COLD_START_GRACE="${WYZE_COLD_START_GRACE:-3600}"    # 1h
WYZE_MOTION_STALE_SECS="${WYZE_MOTION_STALE_SECS:-21600}" # 6h
RESTART_SETTLE_SECS="${RESTART_SETTLE_SECS:-15}"
DRY_RUN="${DRY_RUN:-0}"

OBX_WEBHOOK_URL="${OBX_WEBHOOK_URL:-}"
OBX_TOKEN="${OBX_TOKEN:-}"

# ── pure decision helpers ────────────────────────────────────────────────────
# Extracted verbatim by tests/test-container-health.sh. Keep them side-effect
# free: they are the half that DECIDES, and this script restarts production
# containers.

# http_is_broken <code> -> 0 (broken) / 1 (fine)
# 000 is a transport failure; 500/502 mean the process answered but is failing.
# Anything else — including 401 and 404 — proves the service is up and serving,
# so it must not be restarted.
http_is_broken() {
  case "${1:-000}" in 000|500|502) return 0 ;; *) return 1 ;; esac
}

# started_before <dependent_iso> <postgres_iso> -> 0 if the dependent predates
# Postgres and is therefore holding a dead connection pool.
started_before() {
  local dep_ts pg_ts
  # Guard emptiness EXPLICITLY rather than relying on `date` to reject it.
  # GNU date errors on `date -d ""` and yields 0 here, but other builds return
  # the current time — which compares as newer than the dependent and reads as
  # "restart it". docker inspect returns empty for a container that is not
  # running, so that difference is a restart loop against nothing.
  [ -z "${1:-}" ] && return 1
  [ -z "${2:-}" ] && return 1
  dep_ts=$(date -d "$1" +%s 2>/dev/null || echo 0)
  pg_ts=$(date -d "$2" +%s 2>/dev/null || echo 0)
  [ "$dep_ts" -eq 0 ] && return 1
  [ "$pg_ts" -eq 0 ] && return 1
  [ "$pg_ts" -gt "$dep_ts" ]
}

# motion_is_stale <now> <newest_motion_ts> <threshold> -> 0 if the Events
# subscription looks dead. A newest_motion_ts of 0 means it has NEVER reported,
# which is the drifted-subscription signature rather than a fresh install —
# the caller only reaches here after the cold-start grace has elapsed.
motion_is_stale() {
  local now="${1:-0}" newest="${2:-0}" threshold="${3:-21600}"
  case "$newest" in ''|*[!0-9]*) newest=0 ;; esac
  [ "$newest" -eq 0 ] && return 0
  [ $(( now - newest )) -gt "$threshold" ]
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
  payload=$(printf '{"source":"container-health","level":"%s","action":"%s","detail":"%s"}' \
            "$lvl" "$act" "$(printf '%s' "$rsn" | sed 's/\\/\\\\/g; s/"/\\"/g')")
  curl -s --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${OBX_TOKEN}" \
    -d "$payload" \
    "$OBX_WEBHOOK_URL" >/dev/null 2>&1 || true
}

act() {   # act <description> <command...>
  local what="$1"; shift
  if [ "$DRY_RUN" = "1" ]; then echo "  DRY_RUN: would $what"; return 0; fi
  echo "  $what"
  "$@" 2>&1 | tail -3
}

# Only run the body when executed. Sourcing (as the tests do) must not restart
# anything — the same rule runner-guard.sh follows.
case "${BASH_SOURCE[0]}" in "$0") ;; *) return 0 2>/dev/null || true ;; esac

# Layer 2 and Layer 3 can fire at once; only one may restart things.
exec 9>"$LOCK" 2>/dev/null || { echo "RESULT action=skip level=ok reasons=no-lockfile"; exit 0; }
flock -n 9 || { echo "RESULT action=skip level=ok reasons=another-run-holds-the-lock"; exit 0; }

problems=()
fixes=()
NOW=$(date +%s)

probe() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000; }

# ── SuperTokens → Postgres ───────────────────────────────────────────────────
ST_JWKS=$(probe "$SUPERTOKENS_URL/.well-known/jwks.json")
if http_is_broken "$ST_JWKS"; then
  ST_HELLO=$(probe "$SUPERTOKENS_URL/hello")
  if http_is_broken "$ST_HELLO"; then
    problems+=("supertokens-down(jwks=$ST_JWKS,hello=$ST_HELLO)")
  else
    # Serving /hello but not JWKS is the lost-DB-connection signature.
    problems+=("supertokens-lost-db(jwks=$ST_JWKS)")
  fi
  act "restart supertokens" docker restart infrastructure-supertokens-1
  fixes+=(supertokens)
fi

# ── Hasura → Postgres ────────────────────────────────────────────────────────
HASURA=$(probe "$HASURA_URL/healthz")
if http_is_broken "$HASURA"; then
  problems+=("hasura-unhealthy($HASURA)")
  act "restart hasura" docker restart infrastructure-hasura-1
  fixes+=(hasura)
fi

# ── dependents that predate a Postgres recreate ──────────────────────────────
PG_STARTED=$(docker inspect --format='{{.State.StartedAt}}' "$PG_CONTAINER" 2>/dev/null || echo "")
if [ -n "$PG_STARTED" ]; then
  for container in $PG_DEPENDENTS; do
    CTR_STARTED=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null || echo "")
    [ -z "$CTR_STARTED" ] && continue
    if started_before "$CTR_STARTED" "$PG_STARTED"; then
      svc=$(printf '%s' "$container" | sed 's/infrastructure-//; s/-1$//')
      case " ${fixes[*]:-} " in *" $svc "*) continue ;; esac
      problems+=("$svc-predates-postgres")
      act "restart $container (started before Postgres was recreated)" docker restart "$container"
      fixes+=("$svc")
    fi
  done
fi

# ── Wyze Bridge: hard down ───────────────────────────────────────────────────
WB_RESTARTED=false
WB=$(probe "$WYZE_URL/")
if http_is_broken "$WB"; then
  WB_API=$(probe "$WYZE_URL/api/")
  if http_is_broken "$WB_API"; then
    problems+=("wyze-bridge-down(ui=$WB,api=$WB_API)")
    act "restart $WYZE_CONTAINER" docker restart "$WYZE_CONTAINER"
    fixes+=(wyze-bridge)
    WB_RESTARTED=true
    [ "$DRY_RUN" = "1" ] || sleep "$RESTART_SETTLE_SECS"
  fi
  # The API answering while the UI is slow is not a fault: deliberately no action.
fi

# ── Wyze Bridge: motion staleness ────────────────────────────────────────────
# A different failure from the one above: the bridge stays HTTP-200 while its
# cloud Events subscription drifts and stops delivering motion. The recorder is
# motion-gated, so the logs look healthy and no clips are produced.
if [ "$WB_RESTARTED" = "false" ]; then
  WB_STARTED=$(docker inspect --format='{{.State.StartedAt}}' "$WYZE_CONTAINER" 2>/dev/null || echo "")
  if [ -n "$WB_STARTED" ]; then
    WB_START_TS=$(date -d "$WB_STARTED" +%s 2>/dev/null || echo 0)
    WB_AGE=$(( NOW - WB_START_TS ))
    if [ "$WB_AGE" -ge "$WYZE_COLD_START_GRACE" ]; then
      CAMS=$(curl -s --max-time 5 "$WYZE_URL/" 2>/dev/null \
             | grep -oE 'data-cam="[^"]+"' | cut -d'"' -f2 | sort -u)
      if [ -n "$CAMS" ]; then
        MAX_TS=0
        for cam in $CAMS; do
          TS=$(curl -s --max-time 5 "$WYZE_URL/api/$cam" 2>/dev/null \
               | grep -oE '"motion_ts":[0-9]+' | head -1 | cut -d: -f2)
          TS=${TS:-0}
          case "$TS" in ''|*[!0-9]*) TS=0 ;; esac
          [ "$TS" -gt "$MAX_TS" ] && MAX_TS=$TS
        done
        if motion_is_stale "$NOW" "$MAX_TS" "$WYZE_MOTION_STALE_SECS"; then
          if [ "$MAX_TS" -eq 0 ]; then
            problems+=("wyze-events-never-reported(up=${WB_AGE}s)")
          else
            problems+=("wyze-events-stale($(( NOW - MAX_TS ))s)")
          fi
          act "restart $WYZE_CONTAINER to refresh its cloud Events subscription" \
              docker restart "$WYZE_CONTAINER"
          fixes+=(wyze-bridge-events)
        fi
      fi
    fi
  fi
fi

# ── anything Docker calls unhealthy ──────────────────────────────────────────
UNHEALTHY=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null || echo "")
for container in $UNHEALTHY; do
  [ -z "$container" ] && continue
  SERVICE=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.service"}}' "$container" 2>/dev/null || echo "")
  CONFIG=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container" 2>/dev/null || echo "")
  WORKDIR=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container" 2>/dev/null || echo "")
  problems+=("unhealthy:$container")
  if [ -n "$SERVICE" ] && [ -n "$WORKDIR" ] && [ -n "$CONFIG" ]; then
    # Restart through compose where possible so the container keeps its project
    # labels, networks and aliases; a bare `docker restart` is the fallback.
    if [ "$DRY_RUN" = "1" ]; then
      echo "  DRY_RUN: would compose-restart $SERVICE in $WORKDIR"
    else
      echo "  compose-restart $container ($SERVICE)"
      ( cd "$WORKDIR" && docker compose -f "$(basename "$CONFIG")" restart "$SERVICE" ) 2>&1 | tail -2
    fi
  else
    act "restart $container directly" docker restart "$container"
  fi
  fixes+=("$container")
done

# ── result ───────────────────────────────────────────────────────────────────
level=ok; action=none
if [ "${#fixes[@]}" -gt 0 ]; then level=warn; action="restarted(${#fixes[@]})"; fi
if [ "${#problems[@]}" -gt 0 ] && [ "${#fixes[@]}" -eq 0 ]; then level=critical; action=none; fi
reasons="${problems[*]:-none}"
[ "${#fixes[@]}" -gt 0 ] && reasons="$reasons fixed: ${fixes[*]}"
[ "$DRY_RUN" = "1" ] && action="dry-run"

ts=$(date -Is)
printf '%s level=%s action=%s reasons=%s\n' "$ts" "$level" "$action" "$reasons" >> "$LOG" 2>/dev/null || true
emit "RESULT action=$action level=$level reasons=$reasons"
