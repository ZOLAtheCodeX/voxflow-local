#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[bootstrap] error: python3 not found in PATH"
  echo "[bootstrap] install Python 3.11+ or set PATH to include it"
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

echo "[bootstrap] installing backend dependencies..."
if ! python -m pip install -r "${ROOT_DIR}/backend/requirements.txt"; then
  echo "[bootstrap] error: failed to install requirements"
  echo "[bootstrap] check ${ROOT_DIR}/backend/requirements.txt and network connectivity"
  exit 1
fi

echo "[bootstrap] backend dependencies installed successfully."
