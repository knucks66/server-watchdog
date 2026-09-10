#!/usr/bin/env bash
#
# Install runner-cleanup: the weekly on-box timer that reclaims cold self-hosted
# runner workspaces.
#
# Why this exists: the runners keep PERSISTENT workspaces on purpose — a warm
# node_modules is most of why a tenant build finishes in minutes — and nothing
# ever reclaimed them. On 2026-09-10 the 23 runners held 55G of a 226G disk,
# including a 1.2G node_modules whose repo had not built in 149 days, and 1.7G
# of _diag logs. A one-off cleanup reclaimed 5.4G and would have regrown.
#
# This has no Layer 2 workflow counterpart, unlike the other engines here. It is
# housekeeping with no alerting value: nothing about it needs to be visible from
# outside the box, and running it from GitHub would mean SSHing in to delete
# files on a cadence GitHub throttles anyway.
#
# Idempotent. Run as root, from a checkout of this repo:
#   sudo ./scripts/install-runner-cleanup.sh
#
# Installs:
#   /opt/server-watchdog/runner-cleanup.sh   (the engine, copied from this repo)
#   /etc/systemd/system/runner-cleanup.{service,timer}
# and enables the timer.
#
# To let it push events to Ownersbox/JARVIS, export the creds before running;
# they are written 0600 to /etc/runner-cleanup.env:
#   sudo OBX_WEBHOOK_URL=https://ownersbox.rumio.world/api/watchdog/event \
#        OBX_TOKEN=obx_... ./scripts/install-runner-cleanup.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
INSTALL_DIR=/opt/server-watchdog

echo "=== Installing engine to ${INSTALL_DIR}/runner-cleanup.sh ==="
mkdir -p "$INSTALL_DIR"
install -m 0755 "${HERE}/runner-cleanup.sh" "${INSTALL_DIR}/runner-cleanup.sh"

echo "=== Installing systemd units ==="
install -m 0644 "${REPO}/systemd/runner-cleanup.service" /etc/systemd/system/runner-cleanup.service
install -m 0644 "${REPO}/systemd/runner-cleanup.timer"   /etc/systemd/system/runner-cleanup.timer

echo "=== Ownersbox/JARVIS push creds (optional) ==="
if [ -n "${OBX_WEBHOOK_URL:-}" ] && [ -n "${OBX_TOKEN:-}" ]; then
  ( umask 077; printf 'OBX_WEBHOOK_URL=%s\nOBX_TOKEN=%s\n' "$OBX_WEBHOOK_URL" "$OBX_TOKEN" > /etc/runner-cleanup.env )
  chmod 600 /etc/runner-cleanup.env
  echo "wrote /etc/runner-cleanup.env (0600)"
else
  echo "OBX_WEBHOOK_URL/OBX_TOKEN not in env — leaving /etc/runner-cleanup.env untouched (push stays off)"
fi

echo "=== Enabling timer ==="
systemctl daemon-reload
systemctl enable --now runner-cleanup.timer

echo "=== Status ==="
systemctl status runner-cleanup.timer --no-pager 2>/dev/null | head -6 || true
echo "--- next runs ---"
systemctl list-timers runner-cleanup.timer --no-pager 2>/dev/null | head -3 || true

# DRY_RUN, for the same reason as resource-monitor's installer: this engine
# deletes directories inside live CI workspaces, and an installer must not do
# that as a side effect of being run.
echo "--- one-shot smoke run, DRY_RUN (should print a RESULT line, change nothing) ---"
DRY_RUN=1 "${INSTALL_DIR}/runner-cleanup.sh" || true
echo
echo "Installed. The timer will run for real on its next Sunday tick."
echo "To rehearse without acting:  sudo DRY_RUN=1 ${INSTALL_DIR}/runner-cleanup.sh"
