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

if ! open "\${APP_PATH}"; then
  echo "[launcher] failed to open \${APP_PATH}"
  echo "[launcher] Do NOT launch the raw executable directly — it registers as a"
  echo "[launcher] different TCC client and Accessibility permissions will not persist."
  echo "[launcher] Try: xattr -cr \${APP_PATH} && open \${APP_PATH}"
  exit 1
fi
EOF

chmod +x "${TARGET_PATH}"
echo "[launcher] created: ${TARGET_PATH}"
echo "[launcher] app target: ${APP_PATH}"
