#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[bootstrap-all] bootstrapping backend virtualenv and dependencies..."
"${ROOT_DIR}/scripts/bootstrap_backend.sh"

echo "[bootstrap-all] verifying swift toolchain..."
if ! command -v swift >/dev/null 2>&1; then
  echo "[bootstrap-all] error: swift not found in PATH"
  exit 1
fi

echo "[bootstrap-all] running initial swift build..."
(cd "${ROOT_DIR}" && swift build)

echo "[bootstrap-all] done"
echo "  next steps:"
echo "    ${ROOT_DIR}/scripts/test_all.sh"
echo "    ${ROOT_DIR}/scripts/run_backend.sh"
