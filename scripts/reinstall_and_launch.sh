#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_APP="${HOME}/Applications/VoxFlow.app"

echo "[voxflow] building bundle..."
"${ROOT_DIR}/scripts/build_app_bundle.sh" "$@"

echo "[voxflow] installing bundle..."
"${ROOT_DIR}/scripts/install_app_bundle.sh"

echo "[voxflow] creating desktop launcher..."
"${ROOT_DIR}/scripts/create_desktop_launcher.sh"

echo "[voxflow] launching..."
if ! open "${DEST_APP}"; then
  echo "[voxflow] launchservices open failed; launching executable directly..."
  nohup "${DEST_APP}/Contents/MacOS/VoxFlowLocal" >"${HOME}/Library/Logs/VoxFlow.log" 2>&1 &
  disown || true
  echo "[voxflow] direct launch attempted"
  echo "  log: ${HOME}/Library/Logs/VoxFlow.log"
fi
