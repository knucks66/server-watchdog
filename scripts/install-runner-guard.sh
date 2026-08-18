#!/usr/bin/env bash
#
# Install Layer 3 of the Runner Guard: the on-box systemd timer that runs the
# runner-guard engine every 2 minutes. This is the fast local fail-safe for
# when GitHub is unreachable — critical because ALL runners could be down,
# preventing the Layer 2 GitHub workflow from executing.
#
# Idempotent. Run as root, from a checkout of this repo:
#   sudo ./scripts/install-runner-guard.sh
#
# PREREQUISITE: scripts/install-runner-cgroup-limits.sh must have been applied
# on this box. This guard's step 3 remedies an active-but-offline runner by
# restarting it, and under GitHub's stock KillMode=process a restart orphans the
# Runner.Listener instead of replacing it. Two listeners then fight over one
# agentId, GitHub keeps the runner offline, and this guard restarts it again —
# on 2026-08-18 that loop took 13 of 19 runners offline twice in 20 minutes.
# KillMode=mixed (installed by that script) is what makes this remedy safe.
#
# Installs:
#   /opt/server-watchdog/runner-guard.sh   (the engine)
#   /etc/systemd/system/runner-guard.{service,timer}
# and enables the timer.
#
# Ownersbox/JARVIS push (optional): inherits /etc/load-guard.env automatically.
# To set runner-guard-specific overrides, export OBX_WEBHOOK_URL + OBX_TOKEN:
#   sudo OBX_WEBHOOK_URL=... OBX_TOKEN=... ./scripts/install-runner-guard.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
INSTALL_DIR=/opt/server-watchdog

echo "=== Installing runner-guard engine to ${INSTALL_DIR}/runner-guard.sh ==="
mkdir -p "$INSTALL_DIR"
install -m 0755 "${HERE}/runner-guard.sh" "${INSTALL_DIR}/runner-guard.sh"

echo "=== Installing systemd units ==="
install -m 0644 "${REPO}/systemd/runner-guard.service" /etc/systemd/system/runner-guard.service
install -m 0644 "${REPO}/systemd/runner-guard.timer"   /etc/systemd/system/runner-guard.timer

echo "=== Ownersbox/JARVIS push creds (optional) ==="
if [ -n "${OBX_WEBHOOK_URL:-}" ] && [ -n "${OBX_TOKEN:-}" ]; then
  ( umask 077; printf 'OBX_WEBHOOK_URL=%s\nOBX_TOKEN=%s\n' "$OBX_WEBHOOK_URL" "$OBX_TOKEN" > /etc/runner-guard.env )
  chmod 600 /etc/runner-guard.env
  echo "wrote /etc/runner-guard.env (0600) — Layer 3 will push to Ownersbox"
elif [ -f /etc/load-guard.env ]; then
  echo "no OBX_* in env, but /etc/load-guard.env exists — runner-guard will inherit those creds"
else
  echo "OBX_WEBHOOK_URL/OBX_TOKEN not in env — on-box push stays off"
fi

echo "=== Enabling timer ==="
systemctl daemon-reload
systemctl enable --now runner-guard.timer

echo "=== Status ==="
systemctl status runner-guard.timer --no-pager 2>/dev/null | head -6 || true
echo "--- next runs ---"
systemctl list-timers runner-guard.timer --no-pager 2>/dev/null | head -3 || true
echo "--- one-shot smoke run (should print a RESULT line) ---"
"${INSTALL_DIR}/runner-guard.sh" || true