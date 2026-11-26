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
for fn in is_anonymous_volume disk_action parent_qualifies compose_files_gone never_remove; do
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
echo "compose_files_gone (orphan containers):"
# A container is an orphan only when every compose file it was started from is
# gone. The label is a comma-separated list for a project with two files; read
# as one path it removed the platform API container (2026-11-26).
TMPD=$(mktemp -d)
touch "$TMPD/docker-compose.yml" "$TMPD/docker-compose.override.yml"
check_rc "one file, present: not an orphan" 1 compose_files_gone "$TMPD/docker-compose.yml"
check_rc "one file, missing: orphan" 0 compose_files_gone "$TMPD/gone.yml"
check_rc "two files, both present: not an orphan" 1 compose_files_gone "$TMPD/docker-compose.yml,$TMPD/docker-compose.override.yml"
check_rc "two files, main present, override removed: not an orphan" 1 compose_files_gone "$TMPD/docker-compose.yml,$TMPD/removed.override.yml"
check_rc "two files, only the second present: not an orphan" 1 compose_files_gone "$TMPD/gone.yml,$TMPD/docker-compose.override.yml"
check_rc "two files, both missing: orphan" 0 compose_files_gone "$TMPD/gone.yml,$TMPD/gone2.yml"
check_rc "empty label (not a compose container): not an orphan" 1 compose_files_gone ""
check_rc "label of only commas: not an orphan" 1 compose_files_gone ",,"
rm -rf "$TMPD"

echo
echo "never_remove (what no clean-up may remove):"
# The list as shipped, read from the file, so the test cannot pass against a
# list nobody uses.
NEVER_REMOVE=$(grep -m1 '^NEVER_REMOVE=' "$SRC" | tr -d "$CR" | sed 's/^NEVER_REMOVE="${NEVER_REMOVE:-//; s/}"$//')
check_rc "rumio-functions is never removed" 0 never_remove rumio-functions
check_rc "a shared infrastructure container is never removed" 0 never_remove infrastructure-postgres-1
check_rc "nor one added later (prefix)" 0 never_remove infrastructure-newthing-1
check_rc "nor the dashboard" 0 never_remove ownersbox-dashboard-1
check_rc "a tenant's functions container is not protected" 1 never_remove lettrova-functions
check_rc "a name that only starts like an exact entry is not protected" 1 never_remove rumio-functions-old
check_rc "an empty name is not protected" 1 never_remove ""
NEVER_REMOVE=""
check_rc "an empty list protects nothing" 1 never_remove rumio-functions

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
