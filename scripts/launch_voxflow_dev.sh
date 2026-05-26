#!/usr/bin/env bash
# Fast dev iteration launcher — builds + installs the .app bundle and
# opens it from ~/Applications.
#
# Previously this script launched the raw Mach-O in ``.build/debug/`` with
# ``nohup``. That broke Accessibility persistence: TCC keys on the
# binary's CDHash + path, and the raw debug binary changes both on every
# rebuild. The Session 18 fixup tightened the desktop launcher and the
# bundle open-helper to refuse the raw-Mach-O path; this dev launcher
# also has to follow that rule.
#
# Path now: ``swift build`` -> build_app_bundle.sh -> install_app_bundle.sh
# -> ``open ~/Applications/VoxFlow.app``. Same end state as
# ``reinstall_and_launch.sh`` but without the desktop-launcher refresh
# step (which doesn't change on a code-only iteration).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_APP="${HOME}/Applications/VoxFlow.app"
RUNTIME_DIR="${ROOT_DIR}/.runtime"
BACKEND_LOG="${RUNTIME_DIR}/backend.log"

mkdir -p "${RUNTIME_DIR}"

if ! lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[voxflow] starting backend..."
  nohup "${ROOT_DIR}/scripts/run_backend.sh" >"${BACKEND_LOG}" 2>&1 &
  sleep 1
else
  echo "[voxflow] backend already running on :8765"
fi

echo "[voxflow] building bundle..."
"${ROOT_DIR}/scripts/build_app_bundle.sh" "$@"

echo "[voxflow] installing bundle..."
"${ROOT_DIR}/scripts/install_app_bundle.sh"

echo "[voxflow] launching ${DEST_APP}..."
if ! open "${DEST_APP}"; then
  echo "[voxflow] open(1) failed."
  echo ""
  echo "  Do NOT launch the raw executable directly — it registers as a"
  echo "  different TCC client and Accessibility permissions will not persist."
  echo "  Check quarantine: xattr -cr ${DEST_APP}"
  exit 1
fi

BACKEND_STATUS="$(
  lsof -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null \
    | awk 'NR > 1 { print $1 "(" $2 ")" }' \
    | tr '\n' ' '
)"

echo "[voxflow] launch complete"
echo "  installed app:  ${DEST_APP}"
echo "  backend status: ${BACKEND_STATUS:-not found}"
echo "  backend log:    ${BACKEND_LOG}"
