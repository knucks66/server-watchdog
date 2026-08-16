#!/usr/bin/env bash
#
# Self-hosted GitHub Actions Runner Guard — engine (Layers 2 & 3).
#
# Checks all actions.runner.* systemd units on the box:
#   1. systemctl is-active for each runner service
#   2. Restart any that are inactive/failed
#   3. OPTIONAL: restart units that are ACTIVE but which GitHub reports offline
#   4. Per-runner cooldown prevents restart loops
#   5. Report interventions to Ownersbox via the watchdog event webhook
#
# Step 3 exists because of the 2026-08-16 wedge. Every unit was `active`, so this
# guard skipped all of them — while GitHub had marked all three rumio runners
# offline and CI sat queued for four hours. "Active" only means the process is
# running; it says nothing about whether the runner can still reach GitHub. A
# runner starved of I/O keeps its process alive but stops heartbeating, and the
# local view and GitHub's view silently disagree.
#
# That mismatch is the sharpest available signal for the wedge — load-guard's
# reaper (Layer 4) catches the same class, but only after MAX_JOB_HOURS, whereas
# this catches it as soon as GitHub gives up on the heartbeat.
#
# It needs a token, so it FAILS CLOSED: with no GITHUB_TOKEN the check is skipped
# entirely and logged, and the guard behaves exactly as it did before. Same token
# model as ownersbox's ci-remediation.ts.
#
# Runs identically from the on-box systemd timer (Layer 3) or piped over SSH by
# the GitHub workflow (Layer 2). A flock serializes the two cadences; a
# statefile carries per-runner cooldown across invocations. Must run as root.
#
# The on-box timer (Layer 3) is the PRIMARY recovery path — it survives even
# when ALL runners are down and GitHub Actions can't fire the Layer 2 workflow.
# This is the same circular-dependency protection that load-guard and
# logind-reaper already rely on for their own Layer 3 timers.
#
# Tunables (env):
#   RUNNER_RESTART_COOLDOWN_SECS (default 600) min seconds between restarts of same runner
#   OBX_WEBHOOK_URL / OBX_TOKEN  — Ownersbox push creds (inherited from load-guard.env)
#   OBX_HEARTBEAT_SECS           — heartbeat cadence in seconds (default 900 = 15 min)
#   GITHUB_TOKEN                 — read token with repo administration:read. ABSENT =
#                                  step 3 is skipped entirely (fail-closed).
#   CHECK_GITHUB_OFFLINE (default 1) master switch for step 3.
#   GITHUB_CHECK_EVERY   (default 5) run step 3 only every Nth invocation. At the
#                                  2-minute timer cadence that is ~10 min, which
#                                  keeps ~19 repos well inside the API rate limit.
#   OFFLINE_CONFIRMATIONS (default 2) consecutive checks a runner must appear
#                                  active-locally-but-offline-at-GitHub before we
#                                  act. Absorbs momentary heartbeat blips.

set -uo pipefail

LOCK=/run/runner-guard.lock
STATE=/run/runner-guard.state       # per-runner cooldown: "runner_name=epoch_sec"
LOG=/var/log/runner-guard.log

RUNNER_RESTART_COOLDOWN_SECS="${RUNNER_RESTART_COOLDOWN_SECS:-600}"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
CHECK_GITHUB_OFFLINE="${CHECK_GITHUB_OFFLINE:-1}"
GITHUB_CHECK_EVERY="${GITHUB_CHECK_EVERY:-5}"
OFFLINE_CONFIRMATIONS="${OFFLINE_CONFIRMATIONS:-2}"
TICK_STATE=/run/runner-guard.tick
OFFLINE_STATE=/run/runner-guard.offline   # "<runner>=<consecutive mismatch count>"

OBX_WEBHOOK_URL="${OBX_WEBHOOK_URL:-}"
OBX_TOKEN="${OBX_TOKEN:-}"
OBX_HEARTBEAT_SECS="${OBX_HEARTBEAT_SECS:-900}"
OBX_HB_STATE=/run/runner-guard.obx-heartbeat

emit() {
  local line="$1"
  echo "$line"
  [ -z "$OBX_WEBHOOK_URL" ] && return 0
  [ -z "$OBX_TOKEN" ] && return 0

  local lvl act rsn now raw_esc rsn_esc intervention last now_s
  lvl=$(printf '%s' "$line" | sed -n 's/.*level=\([^ ]*\).*/\1/p')
  act=$(printf '%s' "$line" | sed -n 's/.*action=\([^ ]*\).*/\1/p')
  rsn=$(printf '%s' "$line" | sed -n 's/.*reasons=\([^ ]*\).*/\1/p')
  case "$lvl" in critical*) lvl=critical ;; warn*) lvl=warn ;; *) lvl=ok ;; esac
  [ -z "$act" ] && act=none

  # Intervention = not a quiet healthy run → push immediately.
  # A quiet healthy run pushes a heartbeat only when one is due (throttled).
  intervention=0
  [ "$lvl" != ok ] && intervention=1
  case "$act" in none|"") ;; *) intervention=1 ;; esac
  if [ "$intervention" != 1 ]; then
    last=$(cat "$OBX_HB_STATE" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0 ;; esac
    now_s=$(date +%s)
    [ $(( now_s - last )) -lt "$OBX_HEARTBEAT_SECS" ] && return 0
    act=heartbeat
  fi
  date +%s > "$OBX_HB_STATE" 2>/dev/null || true

  now=$(date -u +%FT%TZ)
  raw_esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
  rsn_esc=$(printf '%s' "$rsn" | sed 's/\\/\\\\/g; s/"/\\"/g')
  curl -fsS -m 10 \
    -H "Authorization: Bearer ${OBX_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"layer\":\"runner-guard\",\"level\":\"${lvl}\",\"action\":\"${act}\",\"target\":\"runner\",\"reason\":\"${rsn_esc}\",\"raw\":\"${raw_esc}\",\"reported_at\":\"${now}\"}" \
    "$OBX_WEBHOOK_URL" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- pure helpers
# These are the decision-making half, kept side-effect free so
# tests/test-runner-offline-check.sh can drive them with fixtures. Everything
# that KILLS or RESTARTS is below; everything that DECIDES is here.

# repo_slug_from_url <gitHubUrl> -> "owner/repo"
#
# The URL comes from the runner's own .runner file and may be STALE: a renamed
# repo keeps the old slug there forever (on this box /opt/github-runner still
# says knucks66/lsg for what is now knucks66/rumio). That is fine — the API
# redirects a renamed repo — but only if the caller follows redirects, so the
# fetch below uses `curl -L`.
repo_slug_from_url() {
  local u="${1:-}"
  case "$u" in https://github.com/*) ;; *) return 0 ;; esac
  u="${u#https://github.com/}"
  u="${u%/}"
  # Exactly two segments. Pure parameter expansion rather than a sed
  # backreference: this is generated/edited by tooling often enough that an
  # escaping slip is a real risk, and a mangled  silently yields "/" — which
  # would then be queried as a repo and quietly fail every tick.
  case "$u" in
    */*/*) return 0 ;;
    */*)   printf '%s
' "$u" ;;
  esac
}

# offline_runner_names <runners-json>
#
# Emits the `name` of every runner GitHub reports as offline. Deliberately keys
# on an EXPLICIT status of "offline": a runner missing from the list entirely has
# been deregistered, and restarting its unit would not bring it back — that is an
# operator problem, not a wedge, and silently restarting would hide it.
offline_runner_names() {
  printf '%s' "${1:-}" | jq -r '(.runners // [])[] | select(.status == "offline") | .name' 2>/dev/null
}

# should_act_on_offline <count> <threshold> -> 0 (act) / 1 (wait)
#
# A single missed heartbeat is not a wedge; GitHub flips a runner to offline
# after a short grace and a busy box can trip that transiently. Requiring
# consecutive confirmations is what keeps this from restarting healthy runners
# during a load spike.
should_act_on_offline() {
  local n="${1:-0}" threshold="${2:-2}"
  case "$n" in (*[!0-9]*|"") return 1 ;; esac
  [ "$n" -ge "$threshold" ]
}

exec 9>"$LOCK" 2>/dev/null || { echo "RESULT action=skip level=ok reason=no-lockfile"; exit 0; }
if ! flock -n 9; then
  echo "RESULT action=skip level=ok reason=already-running"
  exit 0
fi

# Utility: read cooldown state for a given runner; returns epoch seconds or 0.
read_cooldown() {
  local runner="$1" val
  val=$(grep "^${runner}=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2)
  case "$val" in ''|*[!0-9]*) echo 0 ;; *) echo "$val" ;; esac
}

# Utility: write cooldown state for a given runner.
write_cooldown() {
  local runner="$1" epoch="$2"
  grep -v "^${runner}=" "$STATE" 2>/dev/null > "${STATE}.tmp" || true
  printf '%s=%s\n' "$runner" "$epoch" >> "${STATE}.tmp"
  mv "${STATE}.tmp" "$STATE"
}

# --- Discover all actions.runner.* units ---
mapfile -t UNITS < <(
  systemctl list-units 'actions.runner.*' --all --no-legend --plain 2>/dev/null \
    | awk '{print $1, $3}'   # unit name + ACTIVE state (col 3; col 2 is LOAD)
)

if [ "${#UNITS[@]}" -eq 0 ]; then
  emit "RESULT action=none level=ok reason=no-runners"
  exit 0
fi

# ---- Step 3 prep: ask GitHub which runners it considers offline -------------
# One request per REPO (not per runner), on a slower cadence than the unit check.
# Populates OFFLINE_SET as a space-delimited list of agent names.
OFFLINE_SET=" "
github_checked=0

gh_tick=$(cat "$TICK_STATE" 2>/dev/null); case "$gh_tick" in (*[!0-9]*|"") gh_tick=0 ;; esac
gh_tick=$(( gh_tick + 1 ))
echo "$gh_tick" > "$TICK_STATE" 2>/dev/null || true

if [ "$CHECK_GITHUB_OFFLINE" = "1" ] && [ -n "$GITHUB_TOKEN" ]    && [ $(( gh_tick % GITHUB_CHECK_EVERY )) -eq 0 ]; then
  github_checked=1
  seen_repos=" "
  for u in $(systemctl list-units 'actions.runner.*' --all --no-legend --plain 2>/dev/null | awk '{print $1}'); do
    wd=$(systemctl show "$u" -p WorkingDirectory --value 2>/dev/null)
    [ -n "$wd" ] && [ -r "$wd/.runner" ] || continue
    # sed strips the UTF-8 BOM the runner writes into .runner, which jq rejects.
    slug=$(repo_slug_from_url "$(sed '1s/^ï»¿//' "$wd/.runner" 2>/dev/null | jq -r '.gitHubUrl // empty' 2>/dev/null)")
    [ -n "$slug" ] || continue
    case "$seen_repos" in *" $slug "*) continue ;; esac
    seen_repos="${seen_repos}${slug} "

    # -L: a renamed repo (see repo_slug_from_url) answers with a redirect.
    body=$(curl -fsSL -m 15       -H "Authorization: Bearer ${GITHUB_TOKEN}"       -H "Accept: application/vnd.github+json"       -H "X-GitHub-Api-Version: 2022-11-28"       "https://api.github.com/repos/${slug}/actions/runners?per_page=100" 2>/dev/null) || {
        printf '%s GH_QUERY_FAILED repo=%s
' "$(date -u +%FT%TZ)" "$slug" >> "$LOG" 2>/dev/null || true
        continue
      }
    for name in $(offline_runner_names "$body"); do
      OFFLINE_SET="${OFFLINE_SET}${name} "
    done
  done
fi

ts=$(date -u +%FT%TZ)
acted=0
total=0
problems=()
fixes=()

for entry in "${UNITS[@]}"; do
  unit=$(echo "$entry" | awk '{print $1}')
  state=$(echo "$entry" | awk '{print $2}')
  [ -z "$unit" ] && continue
  total=$(( total + 1 ))

  # Extract runner name: actions.runner.<name>.service -> <name>
  runner_name="${unit#actions.runner.}"
  runner_name="${runner_name%.service}"

  # Active unit: the process is up, but that says nothing about whether it can
  # still reach GitHub. Step 3 catches the case where it cannot.
  if [ "$state" = active ]; then
    [ "$github_checked" = 1 ] || continue

    # The unit name is NOT a reliable repo/runner key — a renamed repo keeps its
    # old name in the unit forever. The agent name in .runner is what GitHub
    # reports, so match on that.
    wd=$(systemctl show "$unit" -p WorkingDirectory --value 2>/dev/null)
    agent=""
    [ -n "$wd" ] && [ -r "$wd/.runner" ] &&       agent=$(sed '1s/^ï»¿//' "$wd/.runner" 2>/dev/null | jq -r '.agentName // empty' 2>/dev/null)
    [ -n "$agent" ] || continue

    prev_n=$(grep "^${agent}=" "$OFFLINE_STATE" 2>/dev/null | tail -1 | cut -d= -f2)
    case "$prev_n" in (*[!0-9]*|"") prev_n=0 ;; esac

    case "$OFFLINE_SET" in
      *" $agent "*) mismatch_n=$(( prev_n + 1 )) ;;
      *)            mismatch_n=0 ;;
    esac
    grep -v "^${agent}=" "$OFFLINE_STATE" 2>/dev/null > "${OFFLINE_STATE}.tmp" || true
    printf '%s=%s
' "$agent" "$mismatch_n" >> "${OFFLINE_STATE}.tmp"
    mv "${OFFLINE_STATE}.tmp" "$OFFLINE_STATE" 2>/dev/null || true

    should_act_on_offline "$mismatch_n" "$OFFLINE_CONFIRMATIONS" || continue

    now_s=$(date +%s)
    last_restart=$(read_cooldown "$runner_name")
    if [ "$last_restart" -ne 0 ] && [ $(( now_s - last_restart )) -lt "$RUNNER_RESTART_COOLDOWN_SECS" ]; then
      problems+=("${agent}(offline-cooldown)")
      continue
    fi

    problems+=("${agent}(active-but-offline x${mismatch_n})")
    if systemctl restart "$unit" 2>> "$LOG"; then
      write_cooldown "$runner_name" "$now_s"
      fixes+=("${agent}(offline)")
      acted=$(( acted + 1 ))
      printf '%s RESTARTED_OFFLINE unit=%s agent=%s confirmations=%s
' "$ts" "$unit" "$agent" "$mismatch_n" >> "$LOG" 2>/dev/null || true
      # Reset so the next tick starts a fresh count rather than instantly
      # re-restarting on a stale reading.
      grep -v "^${agent}=" "$OFFLINE_STATE" 2>/dev/null > "${OFFLINE_STATE}.tmp" || true
      mv "${OFFLINE_STATE}.tmp" "$OFFLINE_STATE" 2>/dev/null || true
    else
      printf '%s FAILED_OFFLINE unit=%s agent=%s
' "$ts" "$unit" "$agent" >> "$LOG" 2>/dev/null || true
      fixes+=("${agent}(offline-restart-failed)")
    fi
    continue
  fi

  # Unit is not active — check cooldown.
  now_s=$(date +%s)
  last_restart=$(read_cooldown "$runner_name")
  if [ "$last_restart" -ne 0 ] && [ $(( now_s - last_restart )) -lt "$RUNNER_RESTART_COOLDOWN_SECS" ]; then
    problems+=("${runner_name}(cooldown)")
    continue
  fi

  problems+=("${runner_name}(${state})")

  # Attempt restart.
  if systemctl restart "$unit" 2>> "$LOG"; then
    write_cooldown "$runner_name" "$now_s"
    fixes+=("${runner_name}")
    acted=$(( acted + 1 ))
    printf '%s RESTARTED unit=%s state=%s\n' "$ts" "$unit" "$state" >> "$LOG" 2>/dev/null || true
  else
    printf '%s FAILED unit=%s state=%s\n' "$ts" "$unit" "$state" >> "$LOG" 2>/dev/null || true
    fixes+=("${runner_name}(restart-failed)")
  fi
done

# --- Build result line ---
level=ok
action=none
reasons=""
if [ "$acted" -gt 0 ]; then
  level=warn
  action="restarted(${acted}/${total})"
  reasons="restarted: ${fixes[*]}"
fi
if [ "${#problems[@]}" -gt 0 ]; then
  [ "$acted" -eq 0 ] && level=critical
  reasons="${reasons:+$reasons }problem: ${problems[*]}"
fi

metrics="runners_total=${total} acted=${acted} gh_checked=${github_checked}"
printf '%s level=%s action=%s reasons=%s %s\n' \
  "$ts" "$level" "$action" "$reasons" "$metrics" >> "$LOG" 2>/dev/null || true
emit "RESULT action=$action level=$level reasons=$reasons $metrics"
