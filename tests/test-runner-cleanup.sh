#!/usr/bin/env bash
#
# Tests for runner-cleanup.sh's decision helpers.
#
# The engine deletes directories inside live CI workspaces, so the half that
# DECIDES is the half that gets tested. is_protected_workspace_path matters
# most: on the first real scan of the box, 34 of the 60 matched node_modules
# directories were the runner's own bundled Node runtimes under
# `_work/_update/externals/`, indistinguishable from project dependencies to
# find(1). Deleting those risks the fleet's ability to self-update. The fixtures
# below are those real paths.
#
# Authoring rules, same as the other suites here: no backslash
# line-continuations, and CR is derived at runtime rather than written as a
# literal or as \r. Both otherwise produce failures whose want and got print
# identically.
#
# Run: bash tests/test-runner-cleanup.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../scripts/runner-cleanup.sh"
CR=$(printf '\015')

# Source only the pure helpers — the script takes a flock and deletes trees.
# Extracting from the SHIPPED file means these cannot drift.
for fn in is_protected_workspace_path runner_root_of older_than_days; do
  eval "$(sed -n "/^${fn}() {/,/^}/p" "$SRC" | tr -d "$CR")"
  declare -F "$fn" >/dev/null || { echo "FAIL: could not extract $fn"; exit 1; }
done

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

echo "is_protected_workspace_path:"
# The 34 real false positives. Every one of these must be refused.
check_rc "runner self-update node24 payload is PROTECTED" 0 is_protected_workspace_path \
  /opt/github-runner-rumio/_work/_update/externals/node24/lib/node_modules
check_rc "runner self-update node20 payload is PROTECTED" 0 is_protected_workspace_path \
  /opt/github-runner-taxengine/_work/_update/externals/node20/lib/node_modules
check_rc "any externals path is PROTECTED" 0 is_protected_workspace_path \
  /opt/github-runner-rumio/externals/node20/lib/node_modules
check_rc "diag path is PROTECTED" 0 is_protected_workspace_path \
  /opt/github-runner-rumio/_diag/node_modules

# The hosted TOOL CACHE. Found by the installer's DRY_RUN on the real box, after
# the first version of this predicate shipped protecting only _update. This is
# where actions/setup-node installs Node, and `lib/node_modules` is npm ITSELF —
# setup-node then treats the version as cached and reuses it, so deleting this
# yields a Node with no npm and builds that fail until the cache is cleared by
# hand. This exact path is the one that would have been deleted.
check_rc "hosted tool cache (setup-node) is PROTECTED" 0 is_protected_workspace_path   /opt/github-runner-ai-forge/_work/_tool/node/22.22.1/x64/lib/node_modules
check_rc "tool cache, another runner and version" 0 is_protected_workspace_path   /opt/github-runner-podcastwiz-app/_work/_tool/node/20.20.2/x64/lib/node_modules
# Actions are downloaded once into _actions and re-used; several ship deps.
check_rc "downloaded action deps are PROTECTED" 0 is_protected_workspace_path   /opt/github-runner-rumio/_work/_actions/actions/setup-node/v4/node_modules
check_rc "_temp is PROTECTED" 0 is_protected_workspace_path   /opt/github-runner-rumio/_work/_temp/x/node_modules
# The rule is the leading underscore, not a list of known names, so a directory
# a future runner release invents is protected without a code change.
check_rc "an unknown _-prefixed runner dir is PROTECTED" 0 is_protected_workspace_path   /opt/github-runner-rumio/_work/_somethingnew/deep/node_modules

# The runner INSTALL, above _work. Nothing here is ever a build artifact, and
# .credentials lives at this level.
check_rc "runner install root is PROTECTED" 0 is_protected_workspace_path /opt/github-runner-rumio
check_rc "path with no _work segment is PROTECTED" 0 is_protected_workspace_path /opt/github-runner-rumio/bin/node_modules
check_rc "unrelated absolute path is PROTECTED" 0 is_protected_workspace_path /opt/ownersbox/node_modules
check_rc "empty path is PROTECTED" 0 is_protected_workspace_path ""

# Genuine project dependencies — the only thing this engine may delete.
check_rc "top-level project deps are prunable" 1 is_protected_workspace_path \
  /opt/github-runner-rumio/_work/rumio/rumio/node_modules
check_rc "monorepo package deps are prunable" 1 is_protected_workspace_path \
  /opt/github-runner-rumio/_work/as-isy/as-isy/packages/mobile/node_modules
check_rc "bare-named runner (lsg) deps are prunable" 1 is_protected_workspace_path \
  /opt/github-runner/_work/lsg/lsg/node_modules

echo
echo "runner_root_of:"
check "suffixed runner" "/opt/github-runner-rumio" \
  "$(runner_root_of /opt/github-runner-rumio/_work/rumio/rumio/node_modules)"
# The lsg runner has NO suffix. A fixed-depth path cut would return /opt here
# and this engine would ask whether all of /opt was busy.
check "bare runner keeps its own root" "/opt/github-runner" \
  "$(runner_root_of /opt/github-runner/_work/lsg/lsg/node_modules)"
check "deep monorepo path" "/opt/github-runner-rumio" \
  "$(runner_root_of /opt/github-runner-rumio/_work/as-isy/as-isy/packages/web/node_modules)"
check "no _work segment yields empty" "" "$(runner_root_of /opt/github-runner-rumio/bin)"
check "empty input yields empty" "" "$(runner_root_of '')"

echo
echo "older_than_days:"
NOW=1788000000
DAY=86400
check_rc "31 days old exceeds a 30 day floor" 0 older_than_days $(( NOW - 31*DAY )) "$NOW" 30
check_rc "149 days old (the real worst case) exceeds it" 0 older_than_days $(( NOW - 149*DAY )) "$NOW" 30
check_rc "exactly 30 days is NOT older (boundary)" 1 older_than_days $(( NOW - 30*DAY )) "$NOW" 30
check_rc "29 days is NOT older" 1 older_than_days $(( NOW - 29*DAY )) "$NOW" 30
check_rc "written just now is NOT older" 1 older_than_days "$NOW" "$NOW" 30
# stat prints nothing for a path that vanished mid-scan, which happens here
# because CI writes to these trees while this runs. Reading that as "ancient"
# would delete whatever now occupies the path.
check_rc "empty mtime is NOT older" 1 older_than_days "" "$NOW" 30
check_rc "non-numeric mtime is NOT older" 1 older_than_days "junk" "$NOW" 30
check_rc "empty now is NOT older" 1 older_than_days "$NOW" "" 30
check_rc "empty days is NOT older" 1 older_than_days $(( NOW - 99*DAY )) "$NOW" ""

echo
echo "shipped defaults:"
# The engine's own defaults, asserted against the SHIPPED file so this suite
# cannot keep passing against thresholds nobody uses.
for pair in "NODE_MODULES_AGE_DAYS:30" "DIAG_AGE_DAYS:14"; do
  name=${pair%%:*}; want=${pair##*:}
  got=$(grep -m1 "^${name}=" "$SRC" | grep -oE '[0-9]+' | head -1)
  check "$name default is $want" "$want" "$got"
done
# DRY_RUN must default to acting, not to rehearsing: a timer that silently only
# ever pretends would look healthy in the log and reclaim nothing.
got=$(grep -m1 '^DRY_RUN=' "$SRC" | grep -oE '[0-9]+' | head -1)
check "DRY_RUN defaults to 0 (acts for real)" "0" "$got"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
