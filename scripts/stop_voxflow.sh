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

BACKEND_PIDS="$(lsof -t -iTCP:"${BACKEND_PORT}" -sTCP:LISTEN || true)"
if [[ -n "${BACKEND_PIDS}" ]]; then
  echo "[voxflow] stopping backend: ${BACKEND_PIDS}"
  kill ${BACKEND_PIDS}
else
  echo "[voxflow] backend not running on :${BACKEND_PORT}"
fi

echo "[voxflow] stopped"
