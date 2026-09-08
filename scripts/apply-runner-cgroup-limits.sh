#!/usr/bin/env bash
#
# Layer 1 of the Memory & Load Pressure Guard (docs/load-guard-spec.md).
#
# Bounds the *aggregate* memory of every self-hosted GitHub Actions runner on
# the box by placing them all in a shared `runners.slice` with a hard
# MemoryMax. A runaway build (e.g. the 16-way parallel `vite build` wave that
# caused the 2026-05-28 fleet-wide outage) then gets OOM-killed inside the
# runners' own cgroup instead of starving postgres and the rest of production.
#
# Idempotent — safe to re-run. Run it again once any runner that was busy
# during a prior run goes idle, so it can be restarted into the slice.
#
# Usage (on the server, as root):
#   ./apply-runner-cgroup-limits.sh
# Tunables (env):
#   SLICE_MEM_MAX   (default 7G)  hard ceiling for ALL runner builds combined
#   SLICE_MEM_HIGH  (default 6G)  reclaim-pressure soft limit
#   SLICE_CPU_WEIGHT(default 20)  prod services default to 100, so they win
#   SLICE_IO_WEIGHT (default 20)
#
# Sizing note: prod containers use ~8 GB of the box's ~15.6 GB. 7G for runners
# leaves ~8.6 GB for prod + kernel. Re-measure prod steady-state before
# changing; keep >=1 GB headroom.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root (writes /etc/systemd/system and restarts services)." >&2
  exit 1
fi

SLICE_MEM_MAX="${SLICE_MEM_MAX:-7G}"
SLICE_MEM_HIGH="${SLICE_MEM_HIGH:-6G}"
SLICE_CPU_WEIGHT="${SLICE_CPU_WEIGHT:-20}"
SLICE_IO_WEIGHT="${SLICE_IO_WEIGHT:-20}"

echo "=== 1. Writing runners.slice (MemoryMax=${SLICE_MEM_MAX}, MemoryHigh=${SLICE_MEM_HIGH}) ==="
cat > /etc/systemd/system/runners.slice <<EOF
[Unit]
Description=Resource-bounded slice for self-hosted GitHub Actions runners
Documentation=https://github.com/knucks66/server-watchdog/blob/main/docs/load-guard-spec.md
Before=slices.target

[Slice]
MemoryAccounting=yes
MemoryHigh=${SLICE_MEM_HIGH}
MemoryMax=${SLICE_MEM_MAX}
CPUWeight=${SLICE_CPU_WEIGHT}
IOWeight=${SLICE_IO_WEIGHT}
EOF

echo "=== 2. Adding Slice= + KillMode= drop-in to each actions.runner.* unit ==="
mapfile -t UNITS < <(systemctl list-units 'actions.runner.*' --all --no-legend --plain 2>/dev/null | awk '{print $1}')
if [ "${#UNITS[@]}" -eq 0 ]; then
  echo "No actions.runner.* units found — nothing to do." >&2
  exit 1
fi
for unit in "${UNITS[@]}"; do
  [ -z "$unit" ] && continue
  dir="/etc/systemd/system/${unit}.d"
  mkdir -p "$dir"
  cat > "${dir}/slice.conf" <<EOF
# Managed by server-watchdog/scripts/apply-runner-cgroup-limits.sh
[Service]
Slice=runners.slice
# GitHub's stock unit ships KillMode=process, which signals ONLY runsvc.sh on
# stop. runsvc.sh forwards SIGINT to Runner.Listener; when the listener doesn't
# take it, systemd hits TimeoutStopSec and — because of KillMode=process —
# never SIGKILLs the children. The unit reports stopped while an orphaned
# listener keeps running, so the NEXT start adds a second listener rather than
# replacing the first. Two listeners share one agentId, fight over the session,
# and GitHub flaps the runner offline while systemd insists it is active.
#
# Observed on hetzner-runner-wawmfd 2026-08-17: two listeners (21:04 and 00:30)
# against agentId 2; the runner showed offline for hours and queued every job,
# and killing the orphan brought it online within 40s.
#
# `mixed` keeps SIGTERM going to the main process only, so an in-flight job
# still gets the full TimeoutStopSec (5min) to finish, but anything left in the
# cgroup after that is SIGKILLed instead of orphaned.
KillMode=mixed
EOF
  echo "  drop-in: ${dir}/slice.conf"
done

echo "=== 3. daemon-reload ==="
systemctl daemon-reload

echo "=== 4. Restarting idle runners into the slice (skipping busy ones) ==="
# A runner executing a job has a Runner.Worker process in its cgroup; an idle
# runner has only Runner.Listener. Restarting a busy runner would kill the
# in-flight CI job, so we skip those — they adopt the slice on their next
# (re)start. Re-run this script later to catch them once idle.
SKIPPED=()
for unit in "${UNITS[@]}"; do
  [ -z "$unit" ] && continue
  if systemctl status "$unit" --no-pager 2>/dev/null | grep -q 'Runner.Worker'; then
    echo "  SKIP (busy — has Runner.Worker): $unit"
    SKIPPED+=("$unit")
    continue
  fi
  if systemctl restart "$unit" 2>/dev/null; then
    echo "  restarted into slice: $unit"
  else
    echo "  WARN: restart failed: $unit" >&2
  fi
done

echo "=== 5. Verify ==="
systemctl show runners.slice -p MemoryMax -p MemoryHigh -p CPUWeight -p IOWeight 2>/dev/null || true
echo "--- per-unit Slice assignment (sample) ---"
for unit in "${UNITS[@]:0:3}"; do
  printf '%s -> Slice=%s\n' "$unit" "$(systemctl show "$unit" -p Slice --value 2>/dev/null)"
done

if [ "${#SKIPPED[@]}" -gt 0 ]; then
  echo ""
  echo "NOTE: ${#SKIPPED[@]} busy runner(s) were skipped and are NOT yet in the slice:"
  printf '  %s\n' "${SKIPPED[@]}"
  echo "Re-run this script once they're idle to move them in."
fi
