#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_PYTHON="${ROOT_DIR}/.venv/bin/python"
RUN_RUNTIME_CHECKS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-runtime-checks)
      RUN_RUNTIME_CHECKS=0
      shift
      ;;
    --runtime-checks)
      RUN_RUNTIME_CHECKS=1
      shift
      ;;
    *)
      echo "[test-all] unknown argument: $1"
      echo "[test-all] usage: $0 [--runtime-checks|--skip-runtime-checks]"
      exit 1
      ;;
  esac
done

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "[test-all] error: missing ${VENV_PYTHON}"
  echo "[test-all] run: ${ROOT_DIR}/scripts/bootstrap_backend.sh"
  exit 1
fi

if [[ ${RUN_RUNTIME_CHECKS} -eq 1 ]]; then
  echo "[test-all] runtime checks (readiness + regression)..."
  "${ROOT_DIR}/scripts/prepare_models_and_run_regression.sh"
else
  echo "[test-all] runtime checks skipped (--skip-runtime-checks)"
fi

echo "[test-all] swift tests..."
(cd "${ROOT_DIR}" && swift test)

echo "[test-all] backend tests (venv)..."
"${VENV_PYTHON}" -m pytest "${ROOT_DIR}/backend/tests"

echo "[test-all] all tests passed"
