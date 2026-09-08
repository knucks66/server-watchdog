#!/usr/bin/env bash
#
# Install Layer 3 of resource-monitor: the on-box systemd timer that runs the engine
# every 2 hours.
#
# Why this exists: the Layer 2 GitHub workflow asks for that cadence and does not
# get it. GitHub de-prioritises high-frequency scheduled events, and across the
# seven watchdog workflows it was delivering roughly 7 runs a day with gaps over
# four hours. Unlike load-guard and runner-guard, resource-monitor had no on-box timer at
# all, so the throttled cadence was its ONLY cadence.
#
# Idempotent. Run as root, from a checkout of this repo:
#   sudo ./scripts/install-resource-monitor.sh
#
# Installs:
#   /opt/server-watchdog/resource-monitor.sh   (the engine, copied from this repo)
#   /etc/systemd/system/resource-monitor.{service,timer}
# and enables the timer.
#
# To let Layer 3 push events to Ownersbox/JARVIS (same as the Layer 2 workflow),
# export the creds before running; they are written 0600 to /etc/resource-monitor.env,
# which the service loads via EnvironmentFile:
#   sudo OBX_WEBHOOK_URL=https://ownersbox.rumio.world/api/watchdog/event #        OBX_TOKEN=obx_... ./scripts/install-resource-monitor.sh
# Omit them and the on-box push stays off; detection and remediation run anyway.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
INSTALL_DIR=/opt/server-watchdog

echo "=== Installing engine to ${INSTALL_DIR}/resource-monitor.sh ==="
mkdir -p "$INSTALL_DIR"
install -m 0755 "${HERE}/resource-monitor.sh" "${INSTALL_DIR}/resource-monitor.sh"

echo "=== Installing systemd units ==="
install -m 0644 "${REPO}/systemd/resource-monitor.service" /etc/systemd/system/resource-monitor.service
install -m 0644 "${REPO}/systemd/resource-monitor.timer"   /etc/systemd/system/resource-monitor.timer

echo "=== Ownersbox/JARVIS push creds (optional) ==="
if [ -n "${OBX_WEBHOOK_URL:-}" ] && [ -n "${OBX_TOKEN:-}" ]; then
  ( umask 077; printf 'OBX_WEBHOOK_URL=%s\nOBX_TOKEN=%s\n' "$OBX_WEBHOOK_URL" "$OBX_TOKEN" > /etc/resource-monitor.env )
  chmod 600 /etc/resource-monitor.env
  echo "wrote /etc/resource-monitor.env (0600) — Layer 3 will push to Ownersbox"
else
  echo "OBX_WEBHOOK_URL/OBX_TOKEN not in env — leaving /etc/resource-monitor.env untouched (on-box push stays off)"
fi

echo "=== Enabling timer ==="
systemctl daemon-reload
systemctl enable --now resource-monitor.timer

echo "=== Status ==="
systemctl status resource-monitor.timer --no-pager 2>/dev/null | head -6 || true
echo "--- next runs ---"
systemctl list-timers resource-monitor.timer --no-pager 2>/dev/null | head -3 || true

# The smoke run is DRY_RUN, unlike load-guard's. That engine only observes on a
# healthy box; this one restarts containers and deletes volumes, and an
# installer must not do either as a side effect of being run.
echo "--- one-shot smoke run, DRY_RUN (should print a RESULT line, change nothing) ---"
DRY_RUN=1 "${INSTALL_DIR}/resource-monitor.sh" || true
echo
echo "Installed. The timer will run for real on its next tick."
echo "To rehearse without acting:  sudo DRY_RUN=1 ${INSTALL_DIR}/resource-monitor.sh"
