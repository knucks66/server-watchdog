#!/usr/bin/env bash
#
# Tests for load-guard.sh's select_stale_workers().
#
# This is the half of the reaper that decides what dies, so it is the half that
# gets tested. The fixtures are real `ps -eo pid=,etimes=,args=` shapes taken
# from the 2026-08-16 outage box.
#
# Authoring rules (learned the hard way, see test-runner-offline-check.sh):
# no backslash line-continuations, and CR is derived at runtime rather than
# written as a literal or as \r. Both otherwise produce failures whose want and
# got print identically.
#
# Run: bash tests/test-select-stale-workers.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CR=$(printf '\015')

# Source only the function, not the script: load-guard.sh takes a flock, writes
# /run state and needs root. Extracting the definition keeps the test hermetic
# and means it verifies the SHIPPED text rather than a copy.
eval "$(sed -n '/^select_stale_workers() {/,/^}/p' "$HERE/../scripts/load-guard.sh" | tr -d "$CR")"

if ! declare -F select_stale_workers >/dev/null; then
  echo "FAIL: could not extract select_stale_workers from scripts/load-guard.sh"
  exit 1
fi

pass=0; fail=0
check() {
  local name="$1" want="${2//$CR/}" got="${3//$CR/}"
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else fail=$((fail+1)); printf '  FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$name" "$want" "$got"; fi
}
joined() { tr -d "$CR" | paste -sd, -; }

THREE_H=10800

# The actual wedged workers from 2026-08-16 (2h43m = 9780s) plus their
# listeners, a healthy short worker, and unrelated long-lived processes.
FIXTURE_OUTAGE='2084769 9780 /opt/github-runner-rumio-2/bin.2.336.0/Runner.Worker spawnclient 156 159
2084853 9770 /opt/github-runner-rumio-3/bin.2.336.0/Runner.Worker spawnclient 157 160
2084884 9770 /opt/github-runner/bin.2.336.0/Runner.Worker spawnclient 156 159
1319 901282 /opt/github-runner-rumio-2/bin/Runner.Listener run --startuptype service
8298 901272 postgres: checkpointer
2087476 9700 node /opt/github-runner/_work/rumio/rumio/node_modules/.bin/vite build'

# At 2h43m nothing is over a 3h threshold - the outage would NOT have been reaped
# at 3h until it had run another 17 minutes. That is intended: the threshold is
# about certainty, not speed, and the deadlock does not self-resolve.
check "outage fixture at 3h threshold: nothing yet" "" "$(printf '%s\n' "$FIXTURE_OUTAGE" | select_stale_workers $THREE_H | joined)"

# Same fixture once they have aged past the threshold.
FIXTURE_AGED=$(printf '%s\n' "$FIXTURE_OUTAGE" | awk '{ if ($0 ~ /Runner.Worker/) $2 = $2 + 3600; print }')
check "aged past 3h: exactly the three workers" "2084769:13380s,2084853:13370s,2084884:13370s" "$(printf '%s\n' "$FIXTURE_AGED" | select_stale_workers $THREE_H | joined)"

# The listener is older than ANY threshold and must never be selected - killing
# it takes the runner offline, which is the failure we are preventing.
check "never selects Runner.Listener" "" "$(echo '1319 901282 /opt/github-runner-rumio-2/bin/Runner.Listener run --startuptype service' | select_stale_workers $THREE_H | joined)"

# A normal job must survive. The longest real job on this box is ~50 min.
check "healthy 50-minute worker survives" "" "$(echo '999 3000 /opt/github-runner/bin.2.336.0/Runner.Worker spawnclient 1 2' | select_stale_workers $THREE_H | joined)"

# Long-lived infrastructure must never be selected, however old.
check "postgres at 10 days is never selected" "" "$(echo '8298 901272 postgres: checkpointer' | select_stale_workers $THREE_H | joined)"

# A build process is not the signal - the WORKER's age is. A vite build that is
# itself old under a fresh worker must not be selected here.
check "bare vite build is never selected" "" "$(echo '2087476 99999 node /opt/github-runner/_work/rumio/rumio/node_modules/.bin/vite build' | select_stale_workers $THREE_H | joined)"

# Boundary: strictly greater than, so exactly-at-threshold survives.
check "exactly at threshold survives" "" "$(echo "42 $THREE_H /opt/github-runner/bin/Runner.Worker x" | select_stale_workers $THREE_H | joined)"
check "one second past threshold is selected" "42:10801s" "$(echo "42 $((THREE_H+1)) /opt/github-runner/bin/Runner.Worker x" | select_stale_workers $THREE_H | joined)"

# Malformed ps lines must be skipped, not crash or match.
check "non-numeric etimes is skipped" "" "$(echo 'abc xyz /opt/github-runner/bin/Runner.Worker x' | select_stale_workers $THREE_H | joined)"
check "empty input yields nothing" "" "$(printf '' | select_stale_workers $THREE_H | joined)"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
