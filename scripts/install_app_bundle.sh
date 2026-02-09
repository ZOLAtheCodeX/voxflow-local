#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="${ROOT_DIR}/dist/VoxFlow.app"
DEST_DIR="${HOME}/Applications"
DEST_APP="${DEST_DIR}/VoxFlow.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
NESTED_APP="${DEST_APP}/VoxFlow.app"

is_valid_bundle() {
  local app_path="$1"
  [[ -f "${app_path}/Contents/Info.plist" ]] && [[ -x "${app_path}/Contents/MacOS/VoxFlowLocal" ]]
}

if [[ ! -d "${SRC_APP}" ]]; then
  echo "[install] source bundle missing: ${SRC_APP}"
  echo "[install] build it first with: ${ROOT_DIR}/scripts/build_app_bundle.sh"
  exit 1
fi

if [[ ! -f "${SRC_APP}/Contents/Info.plist" ]]; then
  echo "[install] invalid source bundle: missing Contents/Info.plist"
  exit 1
fi

if [[ ! -x "${SRC_APP}/Contents/MacOS/VoxFlowLocal" ]]; then
  echo "[install] invalid source bundle: missing executable Contents/MacOS/VoxFlowLocal"
  exit 1
fi

mkdir -p "${DEST_DIR}"

if [[ -d "${NESTED_APP}" ]] && ! is_valid_bundle "${DEST_APP}" && is_valid_bundle "${NESTED_APP}"; then
  echo "[install] found nested app bundle; flattening prior broken install..."
  rm -rf "${DEST_APP}.tmp"
  mv "${NESTED_APP}" "${DEST_APP}.tmp"
  rm -rf "${DEST_APP}"
  mv "${DEST_APP}.tmp" "${DEST_APP}"
fi

if [[ -d "${DEST_APP}" ]]; then
  echo "[install] removing existing install..."
  rm -rf "${DEST_APP}"
fi

echo "[install] copying bundle with ditto..."
ditto "${SRC_APP}" "${DEST_APP}"

if command -v codesign >/dev/null 2>&1; then
  echo "[install] applying ad-hoc signature..."
  if ! codesign --force --deep --sign - "${DEST_APP}" >/dev/null 2>&1; then
    echo "[install] warning: ad-hoc signing failed; launcher may reject the app."
  fi
fi

echo "[install] clearing quarantine attributes..."
xattr -cr "${DEST_APP}" || true

if [[ -x "${LSREGISTER}" ]]; then
  echo "[install] registering app with LaunchServices..."
  "${LSREGISTER}" -f "${DEST_APP}" >/dev/null 2>&1 || true
fi

if ! is_valid_bundle "${DEST_APP}"; then
  if [[ -d "${NESTED_APP}" ]] && is_valid_bundle "${NESTED_APP}"; then
    echo "[install] detected nested bundle after copy; repairing..."
    rm -rf "${DEST_APP}.tmp"
    mv "${NESTED_APP}" "${DEST_APP}.tmp"
    rm -rf "${DEST_APP}"
    mv "${DEST_APP}.tmp" "${DEST_APP}"
  fi
fi

if ! is_valid_bundle "${DEST_APP}"; then
  echo "[install] install failed: invalid app structure at ${DEST_APP}"
  echo "[install] expected:"
  echo "  ${DEST_APP}/Contents/Info.plist"
  echo "  ${DEST_APP}/Contents/MacOS/VoxFlowLocal"
  exit 1
fi

echo "[install] done"
echo "  installed app: ${DEST_APP}"
echo "  executable: ${DEST_APP}/Contents/MacOS/VoxFlowLocal"
echo "  launch: open \"${DEST_APP}\""
