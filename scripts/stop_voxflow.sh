#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BIN="${ROOT_DIR}/.build/debug/VoxFlowLocal"

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

BACKEND_PIDS="$(lsof -t -iTCP:8765 -sTCP:LISTEN || true)"
if [[ -n "${BACKEND_PIDS}" ]]; then
  echo "[voxflow] stopping backend: ${BACKEND_PIDS}"
  kill ${BACKEND_PIDS}
else
  echo "[voxflow] backend not running on :8765"
fi

echo "[voxflow] stopped"
