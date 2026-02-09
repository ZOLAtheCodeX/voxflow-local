#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${ROOT_DIR}/.runtime"
APP_BIN="${ROOT_DIR}/.build/debug/VoxFlowLocal"
BACKEND_LOG="${RUNTIME_DIR}/backend.log"
APP_LOG="${RUNTIME_DIR}/app.log"

find_app_pids() {
  pgrep -f "${APP_BIN}" 2>/dev/null || true
}

mkdir -p "${RUNTIME_DIR}"

if ! lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[voxflow] starting backend..."
  nohup "${ROOT_DIR}/scripts/run_backend.sh" >"${BACKEND_LOG}" 2>&1 &
  sleep 1
else
  echo "[voxflow] backend already running on :8765"
fi

if [[ ! -x "${APP_BIN}" ]]; then
  echo "[voxflow] app binary missing, building..."
  (cd "${ROOT_DIR}" && swift build >/dev/null)
fi

if [[ -n "$(find_app_pids)" ]]; then
  echo "[voxflow] app already running"
else
  echo "[voxflow] launching app..."
  nohup "${APP_BIN}" >"${APP_LOG}" 2>&1 &
  sleep 1
fi

APP_PIDS="$(find_app_pids | tr '\n' ' ')"
BACKEND_STATUS="$(
  lsof -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null \
    | awk 'NR > 1 { print $1 "(" $2 ")" }' \
    | tr '\n' ' '
)"

echo "[voxflow] launch complete"
echo "  app process:    ${APP_PIDS:-not found}"
echo "  backend status: ${BACKEND_STATUS:-not found}"
echo "  logs:"
echo "    ${APP_LOG}"
echo "    ${BACKEND_LOG}"
