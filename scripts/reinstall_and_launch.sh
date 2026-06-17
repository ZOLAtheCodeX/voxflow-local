#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_APP="${HOME}/Applications/VoxFlow.app"

echo "[voxflow] building bundle..."
"${ROOT_DIR}/scripts/build_app_bundle.sh" "$@"

echo "[voxflow] installing bundle..."
"${ROOT_DIR}/scripts/install_app_bundle.sh"

# Desktop launcher is opt-in: for a persistently-running menu-bar (LSUIElement)
# app it is redundant with Spotlight/double-click, and dropping a .command on the
# Desktop on every reinstall is surprise clutter. Set VOXFLOW_DESKTOP_LAUNCHER=1
# to recreate it, or run scripts/create_desktop_launcher.sh manually.
if [[ "${VOXFLOW_DESKTOP_LAUNCHER:-0}" == "1" ]]; then
  echo "[voxflow] creating desktop launcher (VOXFLOW_DESKTOP_LAUNCHER=1)..."
  "${ROOT_DIR}/scripts/create_desktop_launcher.sh"
fi

echo "[voxflow] relaunching (quit running instance first — open alone only activates it)..."
osascript -e 'tell application "VoxFlow" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do pgrep -x VoxFlowLocal >/dev/null || break; sleep 0.5; done
pkill -x VoxFlowLocal >/dev/null 2>&1 || true
sleep 1
if ! open "${DEST_APP}"; then
  echo "[voxflow] launchservices open failed."
  echo ""
  echo "  Do NOT launch the raw executable directly — it registers as a"
  echo "  different TCC client and Accessibility permissions will not persist."
  echo ""
  echo "  Try: open ${DEST_APP}"
  echo "  If that fails, check quarantine: xattr -cr ${DEST_APP}"
  exit 1
fi
