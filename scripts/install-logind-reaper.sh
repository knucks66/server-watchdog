#!/usr/bin/env bash
#
# Install Layer 3 of the systemd-logind leaked-session reaper
# (docs/logind-reaper-spec.md): the on-box systemd timer that runs the reaper
# engine every 15 minutes. This is the local path that keeps working even if the
# box can't reach GitHub (Layer 2) — and the only one that still works if logind
# ever did approach the 8192 fd ceiling and started refusing new SSH logins.
#
# Idempotent. Run as root, from a checkout of this repo:
#   sudo ./scripts/install-logind-reaper.sh
#
# Installs:
#   /opt/server-watchdog/logind-reaper.sh   (the engine, copied from this repo)
#   /etc/systemd/system/logind-reaper.{service,timer}
# and enables the timer.
#
# Ownersbox/JARVIS push (optional): the service loads BOTH /etc/load-guard.env
# and /etc/logind-reaper.env (reaper-specific wins). So if you already installed
# load-guard with creds, the reaper inherits them automatically — nothing to do.
# To set reaper-specific creds (or if load-guard isn't installed), export them:
#   sudo OBX_WEBHOOK_URL=https://ownersbox.rumio.world/api/watchdog/event \
#        OBX_TOKEN=obx_... ./scripts/install-logind-reaper.sh
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

echo "=== Installing reaper engine to ${INSTALL_DIR}/logind-reaper.sh ==="
mkdir -p "$INSTALL_DIR"
install -m 0755 "${HERE}/logind-reaper.sh" "${INSTALL_DIR}/logind-reaper.sh"

echo "=== Installing systemd units ==="
install -m 0644 "${REPO}/systemd/logind-reaper.service" /etc/systemd/system/logind-reaper.service
install -m 0644 "${REPO}/systemd/logind-reaper.timer"   /etc/systemd/system/logind-reaper.timer

echo "=== Ownersbox/JARVIS push creds (optional) ==="
if [ -n "${OBX_WEBHOOK_URL:-}" ] && [ -n "${OBX_TOKEN:-}" ]; then
  ( umask 077; printf 'OBX_WEBHOOK_URL=%s\nOBX_TOKEN=%s\n' "$OBX_WEBHOOK_URL" "$OBX_TOKEN" > /etc/logind-reaper.env )
  chmod 600 /etc/logind-reaper.env
  echo "wrote /etc/logind-reaper.env (0600) — Layer 3 will push to Ownersbox"
elif [ -f /etc/load-guard.env ]; then
  echo "no OBX_* in env, but /etc/load-guard.env exists — reaper will inherit those creds"
else
  echo "OBX_WEBHOOK_URL/OBX_TOKEN not in env and no /etc/load-guard.env — on-box push stays off"
fi

echo "=== Enabling timer ==="
systemctl daemon-reload
systemctl enable --now logind-reaper.timer

echo "=== Status ==="
systemctl status logind-reaper.timer --no-pager 2>/dev/null | head -6 || true
echo "--- next runs ---"
systemctl list-timers logind-reaper.timer --no-pager 2>/dev/null | head -3 || true
echo "--- one-shot smoke run (should print a RESULT line) ---"
"${INSTALL_DIR}/logind-reaper.sh" || true
