#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${HOME}/Applications/VoxFlow.app"
APP_BIN="${APP_PATH}/Contents/MacOS/VoxFlowLocal"
HEALTH_URL="${VOXFLOW_BACKEND_URL:-http://127.0.0.1:8765}/v1/ready"
MODELS_DIR_DEFAULT="${ROOT_DIR}/models"

echo "[doctor] VoxFlow install check"

if [[ -d "${APP_PATH}" ]]; then
  echo "[ok] app bundle exists: ${APP_PATH}"
else
  echo "[fail] app bundle missing: ${APP_PATH}"
  echo "       run: ${ROOT_DIR}/scripts/reinstall_and_launch.sh --skip-build"
  exit 1
fi

if [[ -f "${APP_PATH}/Contents/Info.plist" ]]; then
  echo "[ok] bundle Info.plist present"
else
  echo "[fail] bundle Info.plist missing"
  exit 1
fi

if [[ -x "${APP_BIN}" ]]; then
  echo "[ok] executable present: ${APP_BIN}"
else
  echo "[fail] executable missing: ${APP_BIN}"
  exit 1
fi

MODELS_DIR="${VOXFLOW_MODELS_DIR:-${MODELS_DIR_DEFAULT}}"
if [[ -d "${MODELS_DIR}" ]]; then
  echo "[ok] models dir found: ${MODELS_DIR}"
else
  echo "[warn] models dir not found: ${MODELS_DIR}"
fi

if command -v curl >/dev/null 2>&1; then
  if HEALTH_PAYLOAD="$(curl -fsS "${HEALTH_URL}" 2>/dev/null)"; then
    echo "[ok] backend readiness reachable: ${HEALTH_URL}"
    echo "[info] ${HEALTH_PAYLOAD}"
  else
    echo "[warn] backend not reachable: ${HEALTH_URL}"
    echo "       start backend by launching app or running:"
    echo "       ${ROOT_DIR}/scripts/run_backend.sh"
  fi
else
  echo "[warn] curl missing; skipping backend health check"
fi

echo "[doctor] done"
