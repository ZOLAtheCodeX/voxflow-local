#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/dist/VoxFlow.app"
APP_BIN="${APP_DIR}/Contents/MacOS/VoxFlowLocal"
RUNTIME_DIR="${ROOT_DIR}/.runtime"
APP_LOG="${RUNTIME_DIR}/app-direct.log"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "[voxflow] app bundle missing, building first..."
  "${ROOT_DIR}/scripts/build_app_bundle.sh"
fi

echo "[voxflow] opening ${APP_DIR}"
if open "${APP_DIR}"; then
  exit 0
fi

echo "[voxflow] open(1) failed."
echo ""
echo "  Do NOT launch the raw executable directly — it registers as a"
echo "  different TCC client and Accessibility permissions will not persist."
echo ""
echo "  Instead, install the app bundle and launch from ~/Applications:"
echo "    ${ROOT_DIR}/scripts/install_app_bundle.sh"
echo "    open ~/Applications/VoxFlow.app"
exit 1
