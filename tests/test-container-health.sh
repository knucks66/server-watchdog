#!/usr/bin/env bash
#
# Tests for container-health.sh's decision helpers.
#
# The engine restarts production containers, so the half that DECIDES is the half
# that gets tested. http_is_broken matters most: it is the difference between
# "the host answered with an error" and "nothing answered at all", and reading it
# wrong means restarting healthy services on every 404.
#
# Authoring rules, same as the other suites here: no backslash
# line-continuations, and CR is derived at runtime rather than written as a
# literal or as \r. Both otherwise produce failures whose want and got print
# identically.
#
# Run: bash tests/test-container-health.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../scripts/container-health.sh"
CR=$(printf '\015')

# Source only the pure helpers — the script takes a flock and restarts
# containers. Extracting from the SHIPPED file means these cannot drift.
for fn in http_is_broken started_before motion_is_stale required_verdict recreate_recipe; do
  eval "$(sed -n "/^${fn}() {/,/^}/p" "$SRC" | tr -d "$CR")"
  declare -F "$fn" >/dev/null || { echo "FAIL: could not extract $fn"; exit 1; }
done

pass=0; fail=0
check_rc() {
  local name="$1" want="$2"; shift 2
  "$@"; local rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else fail=$((fail+1)); printf '  FAIL %s (rc want=%s got=%s)\n' "$name" "$want" "$rc"; fi
}

echo "http_is_broken:"
# 000 is curl failing to connect at all — the service is not there.
check_rc "000 (no connection) is broken" 0 http_is_broken 000
check_rc "500 is broken" 0 http_is_broken 500
check_rc "502 is broken" 0 http_is_broken 502

# Everything below proves the process is alive and serving. Restarting on these
# would churn healthy containers: SuperTokens answers 401 on an unauthenticated
# probe, and plenty of services 404 a bare path.
check_rc "200 is fine" 1 http_is_broken 200
check_rc "204 is fine" 1 http_is_broken 204
check_rc "301 is fine" 1 http_is_broken 301
check_rc "401 is fine (authenticated endpoint, host is up)" 1 http_is_broken 401
check_rc "403 is fine" 1 http_is_broken 403
check_rc "404 is fine (route missing, service alive)" 1 http_is_broken 404
check_rc "503 is fine (deliberately: a load shedder answering IS the host)" 1 http_is_broken 503
check_rc "empty/missing arg defaults to broken" 0 http_is_broken

echo
echo "started_before:"
# The dependent holds a connection pool to a Postgres that has since been
# recreated, so it must restart. Only true when Postgres is strictly newer.
check_rc "dependent older than postgres -> restart" 0 \
  started_before "2026-09-01T10:00:00Z" "2026-09-01T11:00:00Z"
check_rc "dependent newer than postgres -> leave alone" 1 \
  started_before "2026-09-01T12:00:00Z" "2026-09-01T11:00:00Z"
check_rc "identical timestamps -> leave alone" 1 \
  started_before "2026-09-01T11:00:00Z" "2026-09-01T11:00:00Z"
# An unparseable or absent timestamp must never be read as "older". docker
# inspect returns empty for a container that does not exist, and restarting on
# that would be a restart loop against nothing.
check_rc "empty dependent timestamp -> no action" 1 started_before "" "2026-09-01T11:00:00Z"
check_rc "empty postgres timestamp -> no action" 1 started_before "2026-09-01T10:00:00Z" ""
check_rc "both empty -> no action" 1 started_before "" ""
check_rc "garbage timestamp -> no action" 1 started_before "not-a-date" "2026-09-01T11:00:00Z"

echo
echo "motion_is_stale:"
NOW=1788000000
SIX_H=21600
# The caller only reaches this after the cold-start grace, so "never reported"
# means the cloud Events subscription is dead, not that the bridge just booted.
check_rc "never reported (0) is stale" 0 motion_is_stale "$NOW" 0 "$SIX_H"
check_rc "empty is stale" 0 motion_is_stale "$NOW" "" "$SIX_H"
check_rc "non-numeric is stale" 0 motion_is_stale "$NOW" "junk" "$SIX_H"
check_rc "7h old is stale" 0 motion_is_stale "$NOW" $(( NOW - 25200 )) "$SIX_H"
check_rc "exactly 6h is NOT stale (boundary)" 1 motion_is_stale "$NOW" $(( NOW - SIX_H )) "$SIX_H"
check_rc "1s past 6h is stale" 0 motion_is_stale "$NOW" $(( NOW - SIX_H - 1 )) "$SIX_H"
check_rc "5 minutes old is fine" 1 motion_is_stale "$NOW" $(( NOW - 300 )) "$SIX_H"
check_rc "just now is fine" 1 motion_is_stale "$NOW" "$NOW" "$SIX_H"

echo
echo "required_verdict (containers that must exist):"
check_out() {
  local name="$1" want="$2"; shift 2
  local got; got=$("$@")
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else fail=$((fail+1)); printf '  FAIL %s (want=%s got=%s)\n' "$name" "$want" "$got"; fi
}
# The 2026-11-26 outage: rumio-functions did not exist and the check said ok.
check_out "no such container is missing" missing required_verdict "" 0 120
check_out "running is ok" ok required_verdict running 0 120
# Docker is restarting it, or a person paused it: not this check's to touch.
check_out "restarting is left alone" ok required_verdict restarting 0 120
check_out "paused is left alone" ok required_verdict paused 0 120
# A deploy stops the old container seconds before it starts the new one.
check_out "stopped 30s ago waits (a deploy may be mid-swap)" wait required_verdict exited 30 120
check_out "stopped exactly the grace ago is started" start required_verdict exited 120 120
check_out "stopped an hour ago is started" start required_verdict exited 3600 120
check_out "created and never started, past the grace, is started" start required_verdict created 120 120
check_out "dead past the grace is started" start required_verdict dead 500 120
check_out "a garbage age is not old enough" wait required_verdict exited junk 120
check_out "a state this does not know is not acted on" ok required_verdict removing 9999 120

echo
echo "recreate_recipe (off unless configured):"
RECIPES="rumio-functions=/opt/rumio-platform:rumio-functions ownersbox-dashboard-1=/opt/ownersbox:dashboard"
check_out "a configured name gives its directory and service" "/opt/ownersbox dashboard" recreate_recipe ownersbox-dashboard-1 "$RECIPES"
check_out "the first entry too" "/opt/rumio-platform rumio-functions" recreate_recipe rumio-functions "$RECIPES"
check_rc "a name with no entry has none" 1 recreate_recipe infrastructure-caddy-1 "$RECIPES"
check_rc "nothing configured: none" 1 recreate_recipe rumio-functions ""
check_rc "a name that is only a prefix of an entry has none" 1 recreate_recipe rumio "$RECIPES"
check_rc "an entry with no service is not a recipe" 1 recreate_recipe x "x=/opt/x"

echo
echo "shipped defaults:"
# Nothing is recreated unless a person configures it.
got=$(grep -m1 '^REQUIRED_RECREATE=' "$SRC" | tr -d "$CR")
if [ "$got" = 'REQUIRED_RECREATE="${REQUIRED_RECREATE:-}"' ]; then pass=$((pass+1)); printf '  ok   REQUIRED_RECREATE is empty by default\n'
else fail=$((fail+1)); printf '  FAIL REQUIRED_RECREATE default: %s\n' "$got"; fi
got=$(grep -m1 '^REQUIRED_CONTAINERS=' "$SRC" | tr -d "$CR")
case "$got" in *rumio-functions*) pass=$((pass+1)); printf '  ok   rumio-functions is a required container\n' ;;
  *) fail=$((fail+1)); printf '  FAIL rumio-functions is not on REQUIRED_CONTAINERS\n' ;; esac
for pair in "WYZE_COLD_START_GRACE:3600" "WYZE_MOTION_STALE_SECS:21600"; do
  name=${pair%%:*}; want=${pair##*:}
  got=$(grep -m1 "^${name}=" "$SRC" | grep -oE '[0-9]+' | head -1)
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf '  ok   %s default is %s\n' "$name" "$want"
  else fail=$((fail+1)); printf '  FAIL %s default want=%s got=%s\n' "$name" "$want" "$got"; fi
done

echo
echo "run guard (how the workflow runs it: piped to bash -s, under set -u):"
GUARD=$(grep -m1 '^case "${BASH_SOURCE' "$SRC" | tr -d "$CR")
got=$(printf 'set -u
%s
echo BODY
' "$GUARD" | bash -s 2>&1)
if [ "$got" = "BODY" ]; then pass=$((pass+1)); printf '  ok   piped to bash -s, the body runs
'
else fail=$((fail+1)); printf '  FAIL piped to bash -s: want BODY got %s
' "$got"; fi
TMPG=$(mktemp); printf 'set -u
%s
echo BODY
' "$GUARD" > "$TMPG"
got=$(bash "$TMPG" 2>&1)
if [ "$got" = "BODY" ]; then pass=$((pass+1)); printf '  ok   run as a file, the body runs
'
else fail=$((fail+1)); printf '  FAIL run as a file: want BODY got %s
' "$got"; fi
got=$(bash -c "set -u; source '$TMPG'; echo SOURCED" 2>&1)
if [ "$got" = "SOURCED" ]; then pass=$((pass+1)); printf '  ok   sourced, the body is skipped
'
else fail=$((fail+1)); printf '  FAIL sourced: want SOURCED got %s
' "$got"; fi
rm -f "$TMPG"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
