#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_PATH="${1:-${HOME}/Desktop/VoxFlow.command}"

cat > "${TARGET_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

APP_PATH="\${HOME}/Applications/VoxFlow.app"
APP_BIN="\${APP_PATH}/Contents/MacOS/VoxFlowLocal"

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

# Stamp the launcher with the app icon so the Desktop shortcut matches the
# Waveline identity instead of the generic .command document icon. Uses the
# AppleScript-ObjC bridge (no extra dependencies); failure is cosmetic only.
ICNS_PATH="${HOME}/Applications/VoxFlow.app/Contents/Resources/VoxFlow.icns"
if [[ -f "${ICNS_PATH}" ]]; then
  if osascript -l JavaScript -e "
    ObjC.import('AppKit');
    const img = \$.NSImage.alloc.initWithContentsOfFile('${ICNS_PATH}');
    \$.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, '${TARGET_PATH}', 0);
  " >/dev/null 2>&1; then
    echo "[launcher] icon applied from VoxFlow.icns"
  else
    echo "[launcher] warning: could not set launcher icon (cosmetic only)"
  fi
fi

echo "[launcher] created: ${TARGET_PATH}"
echo "[launcher] app target: ${HOME}/Applications/VoxFlow.app"
