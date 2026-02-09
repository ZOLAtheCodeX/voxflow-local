#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_PATH="${1:-${HOME}/Desktop/VoxFlow.command}"
APP_PATH="${HOME}/Applications/VoxFlow.app"
APP_BIN="${APP_PATH}/Contents/MacOS/VoxFlowLocal"
LOG_PATH="${HOME}/Library/Logs/VoxFlow.log"

cat > "${TARGET_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

APP_PATH="\${HOME}/Applications/VoxFlow.app"
APP_BIN="\${APP_PATH}/Contents/MacOS/VoxFlowLocal"
LOG_PATH="\${HOME}/Library/Logs/VoxFlow.log"

if [[ ! -x "\${APP_BIN}" ]]; then
  echo "[launcher] VoxFlow executable not found: \${APP_BIN}"
  echo "[launcher] run install first:"
  echo "  ${ROOT_DIR}/scripts/reinstall_and_launch.sh --skip-build"
  exit 1
fi

if open "\${APP_PATH}" >/dev/null 2>&1; then
  exit 0
fi

nohup "\${APP_BIN}" >"\${LOG_PATH}" 2>&1 &
disown || true
echo "[launcher] started VoxFlow directly"
echo "[launcher] log: \${LOG_PATH}"
EOF

chmod +x "${TARGET_PATH}"
echo "[launcher] created: ${TARGET_PATH}"
echo "[launcher] app target: ${APP_PATH}"
