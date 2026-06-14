#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"
BACKEND_URL="${VOXFLOW_BACKEND_URL:-http://127.0.0.1:8765}"
READINESS_URL="${BACKEND_URL%/}/v1/ready"
BACKEND_NO_SCHEME="${BACKEND_URL#*://}"
BACKEND_HOSTPORT="${BACKEND_NO_SCHEME%%/*}"
BACKEND_HOST="${BACKEND_HOSTPORT%:*}"
BACKEND_PORT="${BACKEND_HOSTPORT##*:}"

if [[ "${BACKEND_HOST}" == "${BACKEND_PORT}" ]]; then
  BACKEND_HOST="${BACKEND_HOSTPORT}"
  if [[ "${BACKEND_URL}" == https://* ]]; then
    BACKEND_PORT="443"
  else
    BACKEND_PORT="80"
  fi
fi

if [[ -z "${BACKEND_HOST}" ]]; then
  BACKEND_HOST="127.0.0.1"
fi

if ! [[ "${BACKEND_PORT}" =~ ^[0-9]+$ ]]; then
  echo "[backend] error: could not parse backend port from ${BACKEND_URL}"
  exit 1
fi

if [[ ! -d "${VENV_DIR}" ]]; then
  echo "[backend] error: virtualenv missing at ${VENV_DIR}"
  echo "[backend] run: ${ROOT_DIR}/scripts/bootstrap_backend.sh"
  exit 1
fi

if [[ ! -x "${VENV_DIR}/bin/python3" ]]; then
  echo "[backend] error: python3 not found in virtualenv"
  echo "[backend] recreate with: rm -rf ${VENV_DIR} && ${ROOT_DIR}/scripts/bootstrap_backend.sh"
  exit 1
fi

source "${VENV_DIR}/bin/activate"
cd "${ROOT_DIR}/backend/app"

if [[ -z "${VOXFLOW_MODELS_DIR:-}" && -d "${ROOT_DIR}/models" ]]; then
  export VOXFLOW_MODELS_DIR="${ROOT_DIR}/models"
fi

export VOXFLOW_PRIVACY_POLICY_VERSION="${VOXFLOW_PRIVACY_POLICY_VERSION:-2026-02}"
export VOXFLOW_PRIVACY_REQUIRE_CONSENT="${VOXFLOW_PRIVACY_REQUIRE_CONSENT:-1}"
export VOXFLOW_PRIVACY_RAW_CONFIRMATION_REQUIRED="${VOXFLOW_PRIVACY_RAW_CONFIRMATION_REQUIRED:-1}"
# Cloud STT fallback defaults OFF (raw audio can't be redacted); export =1 to opt in.
export VOXFLOW_STT_ALLOW_FALLBACK="${VOXFLOW_STT_ALLOW_FALLBACK:-0}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-/tmp/voxflow-pycache}"

if lsof -nP -iTCP:"${BACKEND_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  if "${ROOT_DIR}/scripts/check_runtime_readiness.sh" >/dev/null 2>&1; then
    echo "[backend] already running and ready at ${READINESS_URL}"
    exit 0
  fi
  echo "[backend] port ${BACKEND_PORT} is in use but runtime readiness failed: ${READINESS_URL}"
  mapfile -t CONFLICT_PIDS < <(lsof -ti "tcp:${BACKEND_PORT}" || true)
  if [[ ${#CONFLICT_PIDS[@]} -gt 0 ]]; then
    echo "[backend] attempting to stop conflicting process(es): ${CONFLICT_PIDS[*]}"
    kill "${CONFLICT_PIDS[@]}" >/dev/null 2>&1 || true
    sleep 1
  fi
  if lsof -nP -iTCP:"${BACKEND_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    if [[ ${#CONFLICT_PIDS[@]} -gt 0 ]]; then
      kill -9 "${CONFLICT_PIDS[@]}" >/dev/null 2>&1 || true
      sleep 1
    fi
  fi
  if lsof -nP -iTCP:"${BACKEND_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[backend] unable to free port ${BACKEND_PORT}. stop the conflicting process and run again."
    exit 1
  fi
fi

exec uvicorn server:app --host "${BACKEND_HOST}" --port "${BACKEND_PORT}" --timeout-graceful-shutdown 4
