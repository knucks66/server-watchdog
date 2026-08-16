#!/usr/bin/env bash
#
# Tests for runner-guard.sh's active-but-offline decision helpers.
#
# The guard restarts runner units, so the half that DECIDES gets tested. Fixtures
# come from the real box: the LSG-renamed rumio runner (whose .runner still says
# knucks66/lsg) and the 2026-08-16 wedge, where every unit was active while
# GitHub reported all three rumio runners offline.
#
# Two authoring rules here, both learned the hard way:
#   - no backslash line-continuations: with CRLF a trailing backslash escapes the
#     CARRIAGE RETURN instead of continuing the line;
#   - CR is written as the octal escape \015, never as a literal or as \r, which
#     get mangled differently by every layer that edits this file.
# Both produce failures whose want and got print identically. Do not "tidy" them.
#
# Run: bash tests/test-runner-offline-check.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../scripts/runner-guard.sh"
CR=$(printf '\015')

# Source only the pure helpers - the script takes a flock, writes /run state and
# restarts services. Extracting from the SHIPPED file means these cannot drift.
for fn in repo_slug_from_url offline_runner_names should_act_on_offline; do
  eval "$(sed -n "/^${fn}() {/,/^}/p" "$SRC" | tr -d "$CR")"
  declare -F "$fn" >/dev/null || { echo "FAIL: could not extract $fn"; exit 1; }
done

pass=0; fail=0
check() {
  local name="$1" want="${2//$CR/}" got="${3//$CR/}"
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf '  FAIL %s\n       want(%s): [%s]\n       got (%s): [%s]\n' "$name" "${#want}" "$want" "${#got}" "$got"
  fi
}
check_rc() {
  local name="$1" want="$2"; shift 2
  "$@"; local rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else fail=$((fail+1)); printf '  FAIL %s (rc want=%s got=%s)\n' "$name" "$want" "$rc"; fi
}
joined() { tr -d "$CR" | paste -sd, -; }

echo "repo_slug_from_url:"
check "plain repo url" "knucks66/rumio" "$(repo_slug_from_url https://github.com/knucks66/rumio)"
# The real /opt/github-runner/.runner still carries the PRE-RENAME slug. It must
# still parse - the API redirect (curl -L) resolves it to knucks66/rumio.
check "stale pre-rename slug still parses" "knucks66/lsg" "$(repo_slug_from_url https://github.com/knucks66/lsg)"
check "trailing slash tolerated" "knucks66/rumio" "$(repo_slug_from_url https://github.com/knucks66/rumio/)"
check "empty input yields nothing" "" "$(repo_slug_from_url '')"
check "non-github url yields nothing" "" "$(repo_slug_from_url https://example.com/a/b)"
check "too many path segments rejected" "" "$(repo_slug_from_url https://github.com/a/b/c)"
check "single segment rejected" "" "$(repo_slug_from_url https://github.com/knucks66)"

echo
echo "offline_runner_names:"
WEDGE='{"total_count":3,"runners":[{"id":21,"name":"hetzner-runner","status":"offline","busy":false},{"id":22,"name":"hetzner-runner-rumio-2","status":"offline","busy":false},{"id":23,"name":"hetzner-runner-rumio-3","status":"offline","busy":false}]}'
check "the wedge: all three selected" "hetzner-runner,hetzner-runner-rumio-2,hetzner-runner-rumio-3" "$(offline_runner_names "$WEDGE" | joined)"

HEALTHY='{"total_count":3,"runners":[{"id":21,"name":"hetzner-runner","status":"online","busy":false},{"id":22,"name":"hetzner-runner-rumio-2","status":"online","busy":true},{"id":23,"name":"hetzner-runner-rumio-3","status":"online","busy":false}]}'
check "healthy fleet selects nothing" "" "$(offline_runner_names "$HEALTHY" | joined)"

# A busy ONLINE runner is doing real work - never select it.
check "online+busy is never selected" "" "$(offline_runner_names '{"runners":[{"name":"r","status":"online","busy":true}]}' | joined)"

# A deregistered runner is absent from the list. Restarting its unit would not
# bring it back, and acting would hide an operator problem.
check "absent runner is not selected" "" "$(offline_runner_names '{"total_count":0,"runners":[]}' | joined)"

MIXED='{"runners":[{"name":"a","status":"online","busy":true},{"name":"b","status":"offline","busy":false},{"name":"c","status":"online","busy":false}]}'
check "mixed fleet selects only the offline one" "b" "$(offline_runner_names "$MIXED" | joined)"

check "malformed json yields nothing" "" "$(offline_runner_names 'not json' | joined)"
check "empty input yields nothing" "" "$(offline_runner_names '' | joined)"

echo
echo "should_act_on_offline (threshold 2):"
check_rc "0 confirmations waits" 1 should_act_on_offline 0 2
check_rc "1 confirmation waits"  1 should_act_on_offline 1 2
check_rc "2 confirmations acts"  0 should_act_on_offline 2 2
check_rc "3 confirmations acts"  0 should_act_on_offline 3 2
check_rc "garbage count waits"   1 should_act_on_offline abc 2
check_rc "empty count waits"     1 should_act_on_offline "" 2

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
