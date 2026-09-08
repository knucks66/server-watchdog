#!/usr/bin/env bash
#
# Install Layer 3 of the Memory & Load Pressure Guard (docs/load-guard-spec.md):
# the on-box systemd timer that runs the guard engine every 2 minutes. This is
# the fast local fail-safe for when GitHub deprioritizes the scheduled Layer 2
# workflow under load.
#
# Idempotent. Run as root, from a checkout of this repo:
#   sudo ./scripts/install-load-guard.sh
#
# Installs:
#   /opt/server-watchdog/load-guard.sh   (the engine, copied from this repo)
#   /etc/systemd/system/load-guard.{service,timer}
# and enables the timer.
#
# To also let Layer 3 push events to Ownersbox/JARVIS (same as the Layer 2
# workflow), export the creds before running, and they're written 0600 to
# /etc/load-guard.env (which the service loads via EnvironmentFile):
#   sudo OBX_WEBHOOK_URL=https://ownersbox.rumio.world/api/watchdog/event \
#        OBX_TOKEN=obx_... ./scripts/install-load-guard.sh
# Omit them and the on-box push simply stays off (detection/remediation run
# regardless).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
INSTALL_DIR=/opt/server-watchdog

echo "=== Installing guard engine to ${INSTALL_DIR}/load-guard.sh ==="
mkdir -p "$INSTALL_DIR"
install -m 0755 "${HERE}/load-guard.sh" "${INSTALL_DIR}/load-guard.sh"

echo "=== Installing systemd units ==="
install -m 0644 "${REPO}/systemd/load-guard.service" /etc/systemd/system/load-guard.service
install -m 0644 "${REPO}/systemd/load-guard.timer"   /etc/systemd/system/load-guard.timer

echo "=== Ownersbox/JARVIS push creds (optional) ==="
if [ -n "${OBX_WEBHOOK_URL:-}" ] && [ -n "${OBX_TOKEN:-}" ]; then
  ( umask 077; printf 'OBX_WEBHOOK_URL=%s\nOBX_TOKEN=%s\n' "$OBX_WEBHOOK_URL" "$OBX_TOKEN" > /etc/load-guard.env )
  chmod 600 /etc/load-guard.env
  echo "wrote /etc/load-guard.env (0600) — Layer 3 will push to Ownersbox"
else
  echo "OBX_WEBHOOK_URL/OBX_TOKEN not in env — leaving /etc/load-guard.env untouched (on-box push stays off)"
fi

echo "=== Enabling timer ==="
systemctl daemon-reload
systemctl enable --now load-guard.timer

echo "=== Status ==="
systemctl status load-guard.timer --no-pager 2>/dev/null | head -6 || true
echo "--- next runs ---"
systemctl list-timers load-guard.timer --no-pager 2>/dev/null | head -3 || true
echo "--- one-shot smoke run (should print a RESULT line) ---"
"${INSTALL_DIR}/load-guard.sh" || true
