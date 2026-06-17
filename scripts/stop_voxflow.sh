#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BIN="${ROOT_DIR}/.build/debug/VoxFlowLocal"

# Resolve the backend port from VOXFLOW_BACKEND_URL the same way run_backend.sh
# does, so stop targets the port the app actually uses (default 8765) rather
# than a hardcoded one.
BACKEND_URL="${VOXFLOW_BACKEND_URL:-http://127.0.0.1:8765}"
BACKEND_NO_SCHEME="${BACKEND_URL#*://}"
BACKEND_HOSTPORT="${BACKEND_NO_SCHEME%%/*}"
BACKEND_HOST="${BACKEND_HOSTPORT%:*}"
BACKEND_PORT="${BACKEND_HOSTPORT##*:}"
if [[ "${BACKEND_HOST}" == "${BACKEND_PORT}" ]]; then
  if [[ "${BACKEND_URL}" == https://* ]]; then
    BACKEND_PORT="443"
  else
    BACKEND_PORT="80"
  fi
fi
if ! [[ "${BACKEND_PORT}" =~ ^[0-9]+$ ]]; then
  BACKEND_PORT="8765"
fi

# Try to find bundle-launched or debug-launched instances by executable name.
# pkill -x matches the exact process name regardless of launch path.
APP_PIDS="$(pgrep -x VoxFlowLocal || true)"
if [[ -z "${APP_PIDS}" ]]; then
  # Secondary: match by debug binary path (older launch method)
  APP_PIDS="$(pgrep -f "${APP_BIN}" || true)"
fi

if [[ -n "${APP_PIDS}" ]]; then
  echo "[voxflow] stopping app: ${APP_PIDS}"
  kill ${APP_PIDS}
else
  echo "[voxflow] app not running"
fi

# Only kill listeners that are actually a VoxFlow backend (dev uvicorn
# `server:app` or the bundled `backend/app/server.py`) — never some unrelated
# service that happens to hold the port.
is_voxflow_backend_pid() {
  local cmd
  cmd="$(ps -p "$1" -o command= 2>/dev/null || true)"
  [[ "${cmd}" == *"server:app"* || "${cmd}" == *"backend/app/server.py"* ]]
}

BACKEND_PIDS="$(lsof -t -iTCP:"${BACKEND_PORT}" -sTCP:LISTEN || true)"
VOXFLOW_BACKEND_PIDS=""
for pid in ${BACKEND_PIDS}; do
  if is_voxflow_backend_pid "${pid}"; then
    VOXFLOW_BACKEND_PIDS="${VOXFLOW_BACKEND_PIDS} ${pid}"
  else
    echo "[voxflow] :${BACKEND_PORT} held by non-VoxFlow pid ${pid} — leaving it alone"
  fi
done
VOXFLOW_BACKEND_PIDS="${VOXFLOW_BACKEND_PIDS# }"
if [[ -n "${VOXFLOW_BACKEND_PIDS}" ]]; then
  echo "[voxflow] stopping backend: ${VOXFLOW_BACKEND_PIDS}"
  kill ${VOXFLOW_BACKEND_PIDS}
else
  echo "[voxflow] backend not running on :${BACKEND_PORT}"
fi

echo "[voxflow] stopped"
