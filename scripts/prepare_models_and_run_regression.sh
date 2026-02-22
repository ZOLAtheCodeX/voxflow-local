#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"
RUNTIME_DIR="${ROOT_DIR}/.runtime"
BACKEND_LOG="${RUNTIME_DIR}/prepare-runtime-backend.log"
STARTED_BACKEND_PID=""

if [[ ! -d "${VENV_DIR}" ]]; then
  echo "[prepare] virtualenv missing; bootstrapping..."
  "${ROOT_DIR}/scripts/bootstrap_backend.sh"
fi

source "${VENV_DIR}/bin/activate"
mkdir -p "${RUNTIME_DIR}"

export VOXFLOW_MODELS_DIR="${VOXFLOW_MODELS_DIR:-${ROOT_DIR}/models}"
mkdir -p "${VOXFLOW_MODELS_DIR}"
export VOXFLOW_STT_ALLOW_FALLBACK="${VOXFLOW_STT_ALLOW_FALLBACK:-1}"
export VOXFLOW_VOXTRAL_SKIP_PRIMARY="${VOXFLOW_VOXTRAL_SKIP_PRIMARY:-1}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-/tmp/voxflow-pycache}"

echo "[prepare] downloading required models into ${VOXFLOW_MODELS_DIR}"
python "${ROOT_DIR}/scripts/download_models.py" --cache-dir "${VOXFLOW_MODELS_DIR}" --skip-translate

echo "[prepare] running readiness check against backend"
if ! "${ROOT_DIR}/scripts/check_runtime_readiness.sh"; then
  echo "[prepare] backend not ready; starting temporary backend for runtime checks"
  "${ROOT_DIR}/scripts/run_backend.sh" >"${BACKEND_LOG}" 2>&1 &
  STARTED_BACKEND_PID="$!"
  trap 'if [[ -n "${STARTED_BACKEND_PID}" ]]; then kill "${STARTED_BACKEND_PID}" >/dev/null 2>&1 || true; fi' EXIT

  READY=0
  for _ in $(seq 1 30); do
    if "${ROOT_DIR}/scripts/check_runtime_readiness.sh" >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 1
  done

  if [[ ${READY} -ne 1 ]]; then
    echo "[prepare] error: backend readiness failed after auto-start"
    echo "[prepare] backend log: ${BACKEND_LOG}"
    tail -n 80 "${BACKEND_LOG}" || true
    exit 1
  fi

  "${ROOT_DIR}/scripts/check_runtime_readiness.sh"
fi

echo "[prepare] running regression suite (voxtral backend routing, safe mode)"
"${ROOT_DIR}/scripts/run_regression_suite.sh" --backends voxtral "$@"
