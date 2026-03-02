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

echo "[voxflow] open(1) failed; attempting direct executable launch..."
if [[ ! -x "${APP_BIN}" ]]; then
  echo "[voxflow] executable not found: ${APP_BIN}"
  exit 1
fi

mkdir -p "${RUNTIME_DIR}"
nohup "${APP_BIN}" >"${APP_LOG}" 2>&1 &
APP_PID=$!
sleep 1
if ! kill -0 "${APP_PID}" >/dev/null 2>&1; then
  echo "[voxflow] direct launch failed (process exited immediately)"
  echo "  check log: ${APP_LOG}"
  echo "  try running executable manually in a normal macOS terminal:"
  echo "  ${APP_BIN}"
  exit 1
fi

echo "[voxflow] launched directly"
echo "  log: ${APP_LOG}"
