#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"

if [[ ! -d "${VENV_DIR}" ]]; then
  echo "[prepare] virtualenv missing; bootstrapping..."
  "${ROOT_DIR}/scripts/bootstrap_backend.sh"
fi

source "${VENV_DIR}/bin/activate"

export VOXFLOW_MODELS_DIR="${VOXFLOW_MODELS_DIR:-${ROOT_DIR}/models}"
mkdir -p "${VOXFLOW_MODELS_DIR}"
export VOXFLOW_STT_ALLOW_FALLBACK="${VOXFLOW_STT_ALLOW_FALLBACK:-1}"
export VOXFLOW_VOXTRAL_SKIP_PRIMARY="${VOXFLOW_VOXTRAL_SKIP_PRIMARY:-1}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-/tmp/voxflow-pycache}"

echo "[prepare] downloading required models into ${VOXFLOW_MODELS_DIR}"
python "${ROOT_DIR}/scripts/download_models.py" --cache-dir "${VOXFLOW_MODELS_DIR}" --skip-translate

echo "[prepare] running readiness check against backend if available"
"${ROOT_DIR}/scripts/check_runtime_readiness.sh" || true

echo "[prepare] running regression suite (voxtral backend routing, safe mode)"
"${ROOT_DIR}/scripts/run_regression_suite.sh" --backends voxtral "$@"
