#!/usr/bin/env bash
#
# Runner workspace cleanup — the shared engine.
#
# The self-hosted runners keep PERSISTENT workspaces, which is deliberate: a
# warm node_modules is most of why a tenant build finishes in minutes. The cost
# is that nothing ever reclaims them. On 2026-09-10 the 23 runners held 55G of a
# 226G disk (32% of everything used), including a 1.2G node_modules for a repo
# whose last build was 149 days earlier, and 1.7G of _diag logs.
#
# This reclaims the parts that are provably cold without touching the parts that
# make builds fast. It is NOT a disk-pressure remediation — resource-monitor.sh
# owns that and only fires at 85%. This runs weekly regardless, so the cold
# stuff never accumulates into an emergency in the first place.
#
# Emits one machine-readable `RESULT ...` line, which callers parse.
#
# Every destructive action honours DRY_RUN=1, which reports what it would do and
# changes nothing. Use it for the first run on a new box.
set -uo pipefail   # NOT -e: find/pgrep return nonzero on "no match".

LOCK=/run/runner-cleanup.lock
LOG=/var/log/runner-cleanup.log

RUNNER_GLOB="${RUNNER_GLOB:-/opt/github-runner*}"
NODE_MODULES_AGE_DAYS="${NODE_MODULES_AGE_DAYS:-30}"
DIAG_AGE_DAYS="${DIAG_AGE_DAYS:-14}"
DRY_RUN="${DRY_RUN:-0}"

OBX_WEBHOOK_URL="${OBX_WEBHOOK_URL:-}"
OBX_TOKEN="${OBX_TOKEN:-}"

# ── pure decision helpers ────────────────────────────────────────────────────
# Extracted verbatim by tests/test-runner-cleanup.sh. Side-effect free: this is
# the half that DECIDES, and this script deletes directories inside live CI
# workspaces.

# is_protected_workspace_path <path> -> 0 if it must NEVER be deleted, 1 if it
# is fair game.
#
# THE important predicate here, and the one a naive `find -name node_modules`
# gets wrong three separate ways. It is a WHITELIST by convention, not a
# blacklist of known-bad directories, because enumerating those is a game you
# lose one directory at a time:
#
#   * The first version protected `_work/_update/externals` (the runner's own
#     bundled Node runtimes, staged by its self-update mechanism). 34 of the 60
#     directories matched on the first real scan were these.
#   * Its DRY_RUN on the box then turned up `_work/_tool/node/22.22.1/x64/lib/
#     node_modules` — the hosted tool cache, where actions/setup-node installs
#     Node. That `lib/node_modules` holds npm ITSELF, and setup-node treats the
#     version as cached and reuses it, so deleting it yields a Node install with
#     no npm and builds that fail until somebody clears the cache by hand.
#   * `_work/_actions/` would have been next: actions are downloaded there once
#     and re-used, several of them shipping their own node_modules.
#
# Every one of those is a directory the RUNNER owns, and the runner names all of
# them with a leading underscore. A repository checkout is `_work/<repo>/<repo>`
# and never starts with one. So the rule is: the first path segment under
# `_work/` must not begin with `_`. That covers _tool, _temp, _actions, _update
# and whatever the next runner release invents.
#
# The path must also sit under a `_work/` directory at all. Everything above
# that is the runner INSTALL — bin/, externals/, .runner, .credentials — and
# nothing in this engine has any business there.
is_protected_workspace_path() {
  local p="${1:-}" rest
  case "$p" in
    *"/externals/"*) return 0 ;;
    *"/_diag/"*)     return 0 ;;
    */_work/*)       ;;
    *)               return 0 ;;
  esac
  rest="${p#*/_work/}"
  case "$rest" in
    _*) return 0 ;;
  esac
  return 1
}

# runner_root_of <path> -> prints the runner install dir, or empty.
#
# Used to ask "is THIS runner busy" before touching anything inside it. Splits
# on `/_work/` rather than counting path components, because the runner dirs are
# not uniformly named: the lsg runner is `/opt/github-runner` with no suffix,
# which a fixed-depth cut would mangle into `/opt`.
runner_root_of() {
  case "${1:-}" in
    */_work/*) printf '%s' "${1%%/_work/*}" ;;
    *)         printf '' ;;
  esac
}

# older_than_days <mtime_epoch> <now_epoch> <days> -> 0 if strictly older.
#
# An unset, empty or non-numeric mtime must read as NOT old. stat returns empty
# for a path that vanished between the find and the check — a race that happens
# here because CI is writing to these trees — and treating that as "ancient"
# would delete whatever now occupies the path.
older_than_days() {
  local mtime="${1:-}" now="${2:-}" days="${3:-}"
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  case "$now"   in ''|*[!0-9]*) return 1 ;; esac
  case "$days"  in ''|*[!0-9]*) return 1 ;; esac
  [ $(( (now - mtime) / 86400 )) -gt "$days" ]
}

# ── side-effecting helpers ───────────────────────────────────────────────────

# runner_is_busy <runner_root> -> 0 if a JOB is executing in it.
#
# Matches Runner.Worker, never Runner.Listener: the listener is running in every
# runner at all times, so matching the install dir alone would report all 23 as
# busy forever and this engine would never reclaim a byte.
runner_is_busy() {
  local root="${1:-}"
  [ -z "$root" ] && return 1
  pgrep -f "${root}/bin[^ ]*/Runner\.Worker" >/dev/null 2>&1
}

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
  payload=$(printf '{"source":"runner-cleanup","level":"%s","action":"%s","detail":"%s"}' \
            "$lvl" "$act" "$(printf '%s' "$rsn" | sed 's/\/\\/g; s/"/\\"/g')")
  curl -s --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${OBX_TOKEN}" \
    -d "$payload" \
    "$OBX_WEBHOOK_URL" >/dev/null 2>&1 || true
}

# ── run ──────────────────────────────────────────────────────────────────────
exec 9>"$LOCK" 2>/dev/null || { echo "RESULT action=skip level=ok reasons=no-lockfile"; exit 0; }
flock -n 9 || { echo "RESULT action=skip level=ok reasons=another-run-holds-the-lock"; exit 0; }

NOW=$(date +%s)
before_kb=$(df -k / | awk 'NR==2{print $4}')
nm_removed=0
diag_removed=0
skipped_busy=0
declare -A busy_seen=()

# ── stale node_modules ───────────────────────────────────────────────────────
while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ -d "$d" ] || continue

  if is_protected_workspace_path "$d"; then
    continue
  fi

  root=$(runner_root_of "$d")
  [ -n "$root" ] || continue

  if runner_is_busy "$root"; then
    if [ -z "${busy_seen[$root]:-}" ]; then
      busy_seen[$root]=1
      skipped_busy=$((skipped_busy + 1))
    fi
    continue
  fi

  mtime=$(stat -c %Y "$d" 2>/dev/null)
  older_than_days "$mtime" "$NOW" "$NODE_MODULES_AGE_DAYS" || continue

  if [ "$DRY_RUN" = "1" ]; then
    echo "would remove $d"
  else
    rm -rf "$d" 2>/dev/null || continue
  fi
  nm_removed=$((nm_removed + 1))
done < <(find $RUNNER_GLOB/_work -maxdepth 6 -type d -name node_modules -prune 2>/dev/null)

# ── stale diag logs ──────────────────────────────────────────────────────────
# Not gated on runner_is_busy: these are append-only logs the runner rotates by
# creating new files, so removing one older than a fortnight cannot disturb a
# job in flight.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ "$DRY_RUN" = "1" ]; then
    diag_removed=$((diag_removed + 1))
    continue
  fi
  rm -f "$f" 2>/dev/null && diag_removed=$((diag_removed + 1))
done < <(find $RUNNER_GLOB/_diag -type f -name '*.log' -mtime "+${DIAG_AGE_DAYS}" 2>/dev/null)

# ── result ───────────────────────────────────────────────────────────────────
after_kb=$(df -k / | awk 'NR==2{print $4}')
freed_mb=$(( (after_kb - before_kb) / 1024 ))
[ "$freed_mb" -lt 0 ] && freed_mb=0

level=ok
action=none
[ "$nm_removed" -gt 0 ] || [ "$diag_removed" -gt 0 ] && action=cleanup
reasons="node_modules=${nm_removed},diag_logs=${diag_removed},freed_mb=${freed_mb},skipped_busy_runners=${skipped_busy}"
[ "$DRY_RUN" = "1" ] && action="dry-run"

ts=$(date -Is)
printf '%s level=%s action=%s reasons=%s\n' "$ts" "$level" "$action" "$reasons" >> "$LOG" 2>/dev/null || true
emit "RESULT action=$action level=$level reasons=$reasons"
