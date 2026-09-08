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
for fn in http_is_broken started_before motion_is_stale; do
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
echo "shipped defaults:"
for pair in "WYZE_COLD_START_GRACE:3600" "WYZE_MOTION_STALE_SECS:21600"; do
  name=${pair%%:*}; want=${pair##*:}
  got=$(grep -m1 "^${name}=" "$SRC" | grep -oE '[0-9]+' | head -1)
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf '  ok   %s default is %s\n' "$name" "$want"
  else fail=$((fail+1)); printf '  FAIL %s default want=%s got=%s\n' "$name" "$want" "$got"; fi
done

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
