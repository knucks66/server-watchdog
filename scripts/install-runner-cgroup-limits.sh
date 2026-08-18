#!/usr/bin/env bash
#
# Install Layer 1 of the Memory & Load Pressure Guard: the runners.slice cgroup
# bounds and the KillMode drop-in that every actions.runner.* unit needs.
#
# Why this installer exists at all. apply-runner-cgroup-limits.sh was a one-shot
# you copied to the box by hand, unlike the load-guard / logind-reaper /
# runner-guard engines which all have installers and a canonical copy under
# /opt/server-watchdog. That left no single source of truth on the server: an
# older copy of the apply script, run later by anyone, silently reverts
# KillMode to stock and re-arms the orphaned-listener wedge (see below). This
# installs the current script alongside its siblings and then runs it.
#
# Idempotent. Run as root, from a checkout of this repo:
#   sudo ./scripts/install-runner-cgroup-limits.sh
#
# Installs:
#   /opt/server-watchdog/apply-runner-cgroup-limits.sh   (the engine)
# then executes it, which writes /etc/systemd/system/runners.slice, writes the
# per-unit slice.conf drop-in, daemon-reloads, and restarts IDLE runners.
#
# Ordering matters and the apply script already gets it right: the drop-in and
# daemon-reload happen BEFORE any restart, so the restarts themselves run under
# KillMode=mixed and cannot orphan a listener.
#
# Run this BEFORE install-runner-guard.sh on a fresh box, or any time after.
# runner-guard's step 3 remedies an active-but-offline runner by restarting it,
# and under the stock KillMode=process a restart orphans the listener rather
# than replacing it — two listeners then fight over one agentId and GitHub keeps
# the runner offline, so the guard restarts it again. On 2026-08-18 that loop
# took 13 of 19 runners offline twice in 20 minutes. The guard's primary
# recovery path is only safe once this has been applied.
#
# Tunables pass straight through to the apply script:
#   SLICE_MEM_MAX SLICE_MEM_HIGH SLICE_CPU_WEIGHT SLICE_IO_WEIGHT

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root (writes /etc/systemd/system and restarts services)." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR=/opt/server-watchdog

echo "=== Installing apply-runner-cgroup-limits engine to ${INSTALL_DIR} ==="
mkdir -p "$INSTALL_DIR"
install -m 0755 "${HERE}/apply-runner-cgroup-limits.sh" "${INSTALL_DIR}/apply-runner-cgroup-limits.sh"

echo "=== Applying (writes runners.slice + per-unit drop-ins, restarts idle runners) ==="
"${INSTALL_DIR}/apply-runner-cgroup-limits.sh"

echo "=== Verify: KillMode across every runner unit (want all 'mixed') ==="
for unit in $(systemctl list-units --type=service --all --no-legend --plain 'actions.runner.*' 2>/dev/null | awk '{print $1}'); do
  [ -z "$unit" ] && continue
  systemctl show "$unit" -p KillMode --value
done | sort | uniq -c

echo "=== Verify: exactly one Runner.Listener per install (orphans show as >1) ==="
ps -o cmd= -ww -C Runner.Listener 2>/dev/null \
  | sed -E 's#^/opt/([^/]+)/.*#\1#' | sort | uniq -c | awk '$1 != 1 { print "  ORPHANED: " $0; found=1 } END { if (!found) print "  all installs have exactly one listener" }'
