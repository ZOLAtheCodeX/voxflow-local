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
PRODUCT_BIN="${ROOT_DIR}/.build/release/VoxFlowLocal"
COPY_VENV=1
BUILD_CONFIGURATION="debug"
SKIP_BUILD=0

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
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--copy-venv|--link-venv] [--debug|--release] [--skip-build]"
      exit 1
      ;;
  esac
done

PRODUCT_BIN="${ROOT_DIR}/.build/${BUILD_CONFIGURATION}/VoxFlowLocal"

mkdir -p "${DIST_DIR}"

if [[ ${SKIP_BUILD} -eq 0 ]]; then
  echo "[bundle] building ${BUILD_CONFIGURATION} binary..."
  if ! (cd "${ROOT_DIR}" && swift build -c "${BUILD_CONFIGURATION}"); then
    if [[ -x "${PRODUCT_BIN}" ]]; then
      echo "[bundle] warning: build failed; using existing binary: ${PRODUCT_BIN}"
    else
      echo "[bundle] build failed and no existing binary found."
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

if [[ -d "${ROOT_DIR}/.venv" ]]; then
  if [[ ${COPY_VENV} -eq 1 ]]; then
    echo "[bundle] copying .venv into app bundle (dereferencing symlinks; this may take a while)..."
    cp -RL "${ROOT_DIR}/.venv" "${RESOURCES_DIR}/venv"
  else
    echo "[bundle] linking .venv into app bundle resources..."
    ln -s "${ROOT_DIR}/.venv" "${RESOURCES_DIR}/venv"
  fi
else
  echo "[bundle] warning: .venv not found. Bundle will rely on system python environment."
fi

echo "[bundle] generating app icon..."
python3 "${ROOT_DIR}/scripts/generate_app_icon.py" --output "${ICONSET_DIR}"
if ! iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_PATH}"; then
  FALLBACK_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"
  echo "[bundle] warning: iconutil failed; falling back to system icon."
  cp "${FALLBACK_ICON}" "${ICNS_PATH}"
fi
rm -rf "${ICONSET_DIR}"

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
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
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>VoxFlow records microphone audio for dictation and transcription.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>VoxFlow uses accessibility insertion and app detection to place dictated text in focused fields.</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  echo "[bundle] applying ad-hoc signature..."
  if ! codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1; then
    echo "[bundle] warning: ad-hoc signing failed; launcher may reject the app bundle."
  fi
fi

echo "[bundle] done"
echo "  app: ${APP_DIR}"
echo "  launch command: open \"${APP_DIR}\""
