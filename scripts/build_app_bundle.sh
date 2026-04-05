#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/VoxFlow.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ICONSET_DIR="${DIST_DIR}/VoxFlow.iconset"
ICNS_PATH="${RESOURCES_DIR}/VoxFlow.icns"
COPY_VENV=1
BUILD_CONFIGURATION="debug"
SKIP_BUILD=0
ALLOW_STALE_BINARY=0
ALLOW_SYSTEM_PYTHON=0
MENU_BAR_ONLY=0
MODULE_CACHE_DIR="${ROOT_DIR}/.build/module-cache"
ICON_TMP_DIR="${DIST_DIR}/.icon-tmp"
ENTITLEMENTS_FILE="${ROOT_DIR}/scripts/release/VoxFlow.entitlements"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy-venv)
      COPY_VENV=1
      shift
      ;;
    --link-venv)
      COPY_VENV=0
      shift
      ;;
    --release)
      BUILD_CONFIGURATION="release"
      shift
      ;;
    --debug)
      BUILD_CONFIGURATION="debug"
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --allow-stale-binary)
      ALLOW_STALE_BINARY=1
      shift
      ;;
    --allow-system-python)
      ALLOW_SYSTEM_PYTHON=1
      shift
      ;;
    --menu-bar-only)
      MENU_BAR_ONLY=1
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--copy-venv|--link-venv] [--debug|--release] [--skip-build] [--allow-stale-binary] [--allow-system-python] [--menu-bar-only]"
      exit 1
      ;;
  esac
done

PRODUCT_BIN="${ROOT_DIR}/.build/${BUILD_CONFIGURATION}/VoxFlowLocal"

mkdir -p "${DIST_DIR}"
mkdir -p "${MODULE_CACHE_DIR}"
mkdir -p "${ICON_TMP_DIR}"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${MODULE_CACHE_DIR}}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${MODULE_CACHE_DIR}}"

if [[ ${SKIP_BUILD} -eq 0 ]]; then
  echo "[bundle] building ${BUILD_CONFIGURATION} binary..."
  if ! (cd "${ROOT_DIR}" && swift build -c "${BUILD_CONFIGURATION}"); then
    if [[ ${ALLOW_STALE_BINARY} -eq 1 && -x "${PRODUCT_BIN}" ]]; then
      echo "[bundle] warning: build failed; using existing binary: ${PRODUCT_BIN}"
    else
      echo "[bundle] build failed."
      echo "[bundle] rerun with --allow-stale-binary to package an existing executable."
      exit 1
    fi
  fi
else
  echo "[bundle] skipping build step (--skip-build)"
fi

if [[ ! -x "${PRODUCT_BIN}" ]]; then
  echo "[bundle] release executable not found: ${PRODUCT_BIN}"
  exit 1
fi

echo "[bundle] creating app bundle structure..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${PRODUCT_BIN}" "${MACOS_DIR}/VoxFlowLocal"
chmod +x "${MACOS_DIR}/VoxFlowLocal"

echo "[bundle] bundling backend resources..."
mkdir -p "${RESOURCES_DIR}/backend"
cp -R "${ROOT_DIR}/backend/app" "${RESOURCES_DIR}/backend/"
rm -rf "${RESOURCES_DIR}/backend/app/__pycache__"

if [[ -d "${ROOT_DIR}/models" ]]; then
  echo "[bundle] bundling local models directory..."
  cp -R "${ROOT_DIR}/models" "${RESOURCES_DIR}/models"
else
  echo "[bundle] warning: models directory not found at ${ROOT_DIR}/models"
fi

if [[ -d "${ROOT_DIR}/.venv" ]]; then
  if [[ ${COPY_VENV} -eq 1 ]]; then
    echo "[bundle] copying .venv into app bundle (dereferencing symlinks; this may take a while)..."
    cp -RL "${ROOT_DIR}/.venv" "${RESOURCES_DIR}/venv"
  else
    echo "[bundle] linking .venv into app bundle resources..."
    ln -s "${ROOT_DIR}/.venv" "${RESOURCES_DIR}/venv"
  fi
else
  if [[ ${ALLOW_SYSTEM_PYTHON} -eq 1 ]]; then
    echo "[bundle] warning: .venv not found. Bundle will rely on system python environment."
  else
    echo "[bundle] error: .venv not found."
    echo "[bundle] run ./scripts/bootstrap_backend.sh, or pass --allow-system-python to bypass."
    exit 1
  fi
fi

echo "[bundle] generating app icon..."
python3 "${ROOT_DIR}/scripts/generate_app_icon.py" --output "${ICONSET_DIR}"
if ! TMPDIR="${ICON_TMP_DIR}" iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_PATH}"; then
  FALLBACK_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"
  echo "[bundle] warning: iconutil failed; falling back to system icon."
  cp "${FALLBACK_ICON}" "${ICNS_PATH}"
fi
rm -rf "${ICONSET_DIR}"
rm -rf "${ICON_TMP_DIR}"

LSUIELEMENT_VALUE="<true/>"
if [[ ${MENU_BAR_ONLY} -eq 0 ]] && [[ ${FORCE_DOCK_ICON:-0} -eq 1 ]]; then
  LSUIELEMENT_VALUE="<false/>"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>VoxFlowLocal</string>
  <key>CFBundleIdentifier</key>
  <string>local.voxflow.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VoxFlow</string>
  <key>CFBundleDisplayName</key>
  <string>VoxFlow</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleIconFile</key>
  <string>VoxFlow</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>local.voxflow.app.automation</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>voxflow</string>
      </array>
    </dict>
  </array>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  ${LSUIELEMENT_VALUE}
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>VoxFlow records microphone audio for dictation and transcription.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>VoxFlow uses accessibility insertion and app detection to place dictated text in focused fields.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>VoxFlow uses Accessibility to insert dictated text into focused fields.</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  echo "[bundle] applying ad-hoc signature..."
  if [[ -f "${ENTITLEMENTS_FILE}" ]]; then
    if ! codesign --force --sign - --entitlements "${ENTITLEMENTS_FILE}" "${APP_DIR}" >/dev/null 2>&1; then
      echo "[bundle] warning: ad-hoc signing failed; launcher may reject the app bundle."
    fi
  elif ! codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1; then
    echo "[bundle] warning: ad-hoc signing failed; launcher may reject the app bundle."
  fi
fi

echo "[bundle] done"
echo "  app: ${APP_DIR}"
if [[ ${MENU_BAR_ONLY} -eq 1 ]]; then
  echo "  mode: menu bar only"
else
  echo "  mode: standard app + menu bar"
fi
echo "  launch command: open \"${APP_DIR}\""
