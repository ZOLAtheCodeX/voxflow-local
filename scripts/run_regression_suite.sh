#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"

if [[ ! -d "${VENV_DIR}" ]]; then
  echo "Virtualenv missing. Run scripts/bootstrap_backend.sh first."
  exit 1
fi

source "${VENV_DIR}/bin/activate"

if [[ -z "${VOXFLOW_MODELS_DIR:-}" && -d "${ROOT_DIR}/models" ]]; then
  export VOXFLOW_MODELS_DIR="${ROOT_DIR}/models"
fi
export VOXFLOW_STT_ALLOW_FALLBACK="${VOXFLOW_STT_ALLOW_FALLBACK:-1}"
export VOXFLOW_VOXTRAL_SKIP_PRIMARY="${VOXFLOW_VOXTRAL_SKIP_PRIMARY:-1}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-/tmp/voxflow-pycache}"

python "${ROOT_DIR}/backend/tests/generate_golden_clips.py"
python "${ROOT_DIR}/backend/tests/run_regression_suite.py" "$@"
