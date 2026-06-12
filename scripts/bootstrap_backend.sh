#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[bootstrap] error: python3 not found in PATH"
  echo "[bootstrap] install Python 3.11+ or set PATH to include it"
  exit 1
fi

PYTHON_VERSION="$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")"
if ! python3 -c "import sys; assert sys.version_info >= (3, 11)" 2>/dev/null; then
  echo "[bootstrap] error: Python 3.11+ required (found ${PYTHON_VERSION})"
  exit 1
fi

echo "[bootstrap] creating virtual environment at ${VENV_DIR}..."
if ! python3 -m venv "${VENV_DIR}"; then
  echo "[bootstrap] error: failed to create virtual environment"
  exit 1
fi

source "${VENV_DIR}/bin/activate"

echo "[bootstrap] upgrading pip..."
python -m pip install --upgrade pip

echo "[bootstrap] installing backend dependencies (runtime + test)..."
if ! python -m pip install -r "${ROOT_DIR}/backend/requirements-dev.txt"; then
  echo "[bootstrap] error: failed to install requirements"
  echo "[bootstrap] check ${ROOT_DIR}/backend/requirements-dev.txt and network connectivity"
  exit 1
fi

echo "[bootstrap] backend dependencies installed successfully."
