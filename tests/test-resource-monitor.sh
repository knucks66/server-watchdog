#!/usr/bin/env bash
#
# Tests for resource-monitor.sh's decision helpers.
#
# The engine deletes volumes and removes containers, so the half that DECIDES is
# the half that gets tested. is_anonymous_volume is the one that matters most:
# on 2026-08-05 this box had 133 unreferenced volumes, five of them named,
# including `podcastwiz_postgres-data` — a live Postgres data directory that a
# blanket `docker volume prune` would have destroyed. The fixtures below are
# those real names.
#
# Authoring rules, same as the other suites here: no backslash
# line-continuations, and CR is derived at runtime rather than written as a
# literal or as \r. Both otherwise produce failures whose want and got print
# identically.
#
# Run: bash tests/test-resource-monitor.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../scripts/resource-monitor.sh"
CR=$(printf '\015')

# Source only the pure helpers — the script takes a flock, prunes volumes and
# removes containers. Extracting from the SHIPPED file means these cannot drift.
for fn in is_anonymous_volume disk_action parent_qualifies; do
  eval "$(sed -n "/^${fn}() {/,/^}/p" "$SRC" | tr -d "$CR")"
  declare -F "$fn" >/dev/null || { echo "FAIL: could not extract $fn"; exit 1; }
done

# The helpers read these; the shipped defaults are asserted separately below.
# Each carries its own SC2034 waiver: they are consumed by the eval-extracted
# helpers above, which shellcheck cannot see through. Remove them and
# disk_action / parent_qualifies compare against an unset variable under `set -u`.
# shellcheck disable=SC2034
DISK_CRIT_PCT=85
# shellcheck disable=SC2034
DISK_WARN_PCT=70
# shellcheck disable=SC2034
ZOMBIE_PER_PARENT_MIN=10

pass=0; fail=0
check() {
  local name="$1" want="${2//$CR/}" got="${3//$CR/}"
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf '  FAIL %s\n       want: [%s]\n       got : [%s]\n' "$name" "$want" "$got"
  fi
}
check_rc() {
  local name="$1" want="$2"; shift 2
  "$@"; local rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else fail=$((fail+1)); printf '  FAIL %s (rc want=%s got=%s)\n' "$name" "$want" "$rc"; fi
}

echo "is_anonymous_volume:"
ANON=$(printf 'a%.0s' $(seq 1 64))              # 64 hex chars
ANON_REAL=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
check_rc "64 hex chars is anonymous" 0 is_anonymous_volume "$ANON"
check_rc "realistic docker id is anonymous" 0 is_anonymous_volume "$ANON_REAL"

# The five real named volumes from the 2026-08-05 audit. Every one of these must
# be refused: a false positive here deletes a production database.
check_rc "podcastwiz_postgres-data is NOT anonymous" 1 is_anonymous_volume podcastwiz_postgres-data
check_rc "infrastructure_postgres_data is NOT anonymous" 1 is_anonymous_volume infrastructure_postgres_data
check_rc "minio_data is NOT anonymous" 1 is_anonymous_volume minio_data
check_rc "caddy_data is NOT anonymous" 1 is_anonymous_volume caddy_data
check_rc "meilisearch_data is NOT anonymous" 1 is_anonymous_volume meilisearch_data

# Length is part of the test, not just the alphabet: a short all-hex name like
# `deadbeef` is something a human typed, not an id Docker generated.
check_rc "short all-hex name is NOT anonymous" 1 is_anonymous_volume deadbeef
check_rc "63 hex chars is NOT anonymous" 1 is_anonymous_volume "${ANON_REAL:0:63}"
check_rc "65 hex chars is NOT anonymous" 1 is_anonymous_volume "${ANON_REAL}a"
check_rc "uppercase hex is NOT anonymous" 1 is_anonymous_volume "$(printf 'A%.0s' $(seq 1 64))"
check_rc "empty string is NOT anonymous" 1 is_anonymous_volume ""

echo
echo "disk_action:"
check "0% is ok" "ok" "$(disk_action 0)"
check "69% is ok" "ok" "$(disk_action 69)"
check "70% starts monitoring" "monitor" "$(disk_action 70)"
check "84% still only monitors" "monitor" "$(disk_action 84)"
check "85% triggers cleanup" "cleanup" "$(disk_action 85)"
check "98% triggers cleanup" "cleanup" "$(disk_action 98)"
# df can fail and yield an empty or non-numeric reading. Treating that as 100
# would prune on a bad parse; treating it as ok is the safe direction.
check "empty reading is ok, never cleanup" "ok" "$(disk_action '')"
check "non-numeric reading is ok, never cleanup" "ok" "$(disk_action 'N/A')"

echo
echo "parent_qualifies:"
check_rc "10 zombies qualifies" 0 parent_qualifies 10
check_rc "40 zombies qualifies" 0 parent_qualifies 40
check_rc "9 zombies does not" 1 parent_qualifies 9
check_rc "1 zombie does not" 1 parent_qualifies 1
check_rc "0 does not" 1 parent_qualifies 0
check_rc "non-numeric does not" 1 parent_qualifies "x"
check_rc "empty does not" 1 parent_qualifies ""

echo
echo "shipped defaults:"
# The tests above set these explicitly, so assert the SHIPPED file agrees —
# otherwise this suite would keep passing against thresholds nobody uses.
for pair in "DISK_CRIT_PCT:-85" "DISK_WARN_PCT:-70" "ZOMBIE_PER_PARENT_MIN:-10"; do
  name=${pair%%:*}
  want=${pair##*-}
  got=$(grep -m1 "^${name}=" "$SRC" | grep -oE '[0-9]+' | head -1)
  check "$name default is $want" "$want" "$got"
done

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
