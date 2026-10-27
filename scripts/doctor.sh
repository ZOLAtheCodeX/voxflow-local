#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${HOME}/Applications/VoxFlow.app"
APP_BIN="${APP_PATH}/Contents/MacOS/VoxFlowLocal"
HEALTH_URL="${VOXFLOW_BACKEND_URL:-http://127.0.0.1:8765}/v1/ready"
MODELS_DIR_DEFAULT="${ROOT_DIR}/models"

# shellcheck source=lib/backend_token.sh
source "${ROOT_DIR}/scripts/lib/backend_token.sh"

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
  AUTH_HEADER=""
  if BACKEND_TOKEN="$(voxflow_backend_token)"; then
    AUTH_HEADER="X-VoxFlow-Token: ${BACKEND_TOKEN}"
  else
    echo "[warn] no backend token found; start the app or scripts/run_backend.sh first (looked in $(voxflow_token_dir)/backend.token)"
  fi
  TMP_BODY="$(mktemp)"
  # The header goes in over stdin (-H @-) so the token never appears in argv,
  # and only when a token was found.
  if [[ -n "${AUTH_HEADER}" ]]; then
    HTTP_CODE="$(printf '%s\n' "${AUTH_HEADER}" | curl -sS -H @- -o "${TMP_BODY}" -w "%{http_code}" "${HEALTH_URL}" 2>/dev/null || true)"
  else
    HTTP_CODE="$(curl -sS -o "${TMP_BODY}" -w "%{http_code}" "${HEALTH_URL}" 2>/dev/null || true)"
  fi
  HEALTH_PAYLOAD="$(cat "${TMP_BODY}" 2>/dev/null || true)"
  rm -f "${TMP_BODY}"
  if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "[ok] backend readiness reachable: ${HEALTH_URL}"
    echo "[info] ${HEALTH_PAYLOAD}"
  elif [[ "${HTTP_CODE}" == "401" ]]; then
    echo "[warn] backend rejected the token (HTTP 401): ${HEALTH_URL}"
    echo "       the token file may belong to a previous backend run; restart the app or backend"
  elif [[ -n "${HTTP_CODE}" && "${HTTP_CODE}" != "000" ]]; then
    echo "[warn] backend returned HTTP ${HTTP_CODE}: ${HEALTH_URL}"
  else
    echo "[warn] backend not reachable: ${HEALTH_URL}"
    echo "       start backend by launching app or running:"
    echo "       ${ROOT_DIR}/scripts/run_backend.sh"
  fi
else
  echo "[warn] curl missing; skipping backend health check"
fi

echo "[doctor] done"
