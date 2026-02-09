#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"

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
export VOXFLOW_STT_ALLOW_FALLBACK="${VOXFLOW_STT_ALLOW_FALLBACK:-1}"
export VOXFLOW_VOXTRAL_SKIP_PRIMARY="${VOXFLOW_VOXTRAL_SKIP_PRIMARY:-1}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-/tmp/voxflow-pycache}"

exec uvicorn server:app --host 127.0.0.1 --port 8765
