#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="${ROOT_DIR}/dist/VoxFlow.app"
DEST_DIR="${HOME}/Applications"
DEST_APP="${DEST_DIR}/VoxFlow.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
NESTED_APP="${DEST_APP}/VoxFlow.app"
STAGED_APP="${DEST_DIR}/.VoxFlow.app.staging.$$"
ENTITLEMENTS_FILE="${ROOT_DIR}/scripts/VoxFlow.entitlements"

cleanup_staging() {
  rm -rf "${STAGED_APP}" 2>/dev/null || true
}

trap cleanup_staging EXIT

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

cleanup_staging

echo "[install] copying bundle to staging location..."
ditto "${SRC_APP}" "${STAGED_APP}"

if ! is_valid_bundle "${STAGED_APP}"; then
  echo "[install] staging copy is invalid: ${STAGED_APP}"
  echo "[install] expected:"
  echo "  ${STAGED_APP}/Contents/Info.plist"
  echo "  ${STAGED_APP}/Contents/MacOS/VoxFlowLocal"
  exit 1
fi

SIGN_IDENTITY="${VOXFLOW_SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
fi

if [[ -z "${SIGN_IDENTITY}" ]]; then
  if [[ "${VOXFLOW_ALLOW_ADHOC:-}" == "1" ]]; then
    echo "[install] WARNING: no Apple Development certificate found — signing ad-hoc (--sign -)."
    echo "[install] WARNING: with ad-hoc signing macOS resets the Accessibility grant on every"
    echo "[install]          rebuild, so you re-approve VoxFlow in System Settings each time."
    echo "[install]          A FREE Apple ID gives you an 'Apple Development' certificate via"
    echo "[install]          Xcode that makes the grant persist — see README 'Building from source'."
    SIGN_IDENTITY="-"
  else
    echo "[install] error: no Apple Development signing identity found. Two ways forward:"
    echo "[install]   1. (recommended, free) Sign in to Xcode with any Apple ID to get an"
    echo "[install]      'Apple Development' certificate; Accessibility permissions then persist."
    echo "[install]   2. Install unsigned now: re-run with VOXFLOW_ALLOW_ADHOC=1 (the app works,"
    echo "[install]      but you re-grant Accessibility after each rebuild)."
    echo "[install] Or set VOXFLOW_SIGN_IDENTITY to a specific identity."
    exit 1
  fi
fi

if [[ "${SIGN_IDENTITY}" == "-" ]]; then
  echo "[install] signing ad-hoc (Accessibility grant will not persist across rebuilds)"
else
  echo "[install] signing with identity: ${SIGN_IDENTITY}"
fi
if [[ -f "${ENTITLEMENTS_FILE}" ]]; then
  if ! codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${ENTITLEMENTS_FILE}" "${STAGED_APP}"; then
    echo "[install] error: signing failed with identity: ${SIGN_IDENTITY}"
    exit 1
  fi
else
  if ! codesign --force --sign "${SIGN_IDENTITY}" "${STAGED_APP}"; then
    echo "[install] error: signing failed with identity: ${SIGN_IDENTITY}"
    exit 1
  fi
fi

echo "[install] clearing quarantine attributes on staged app..."
xattr -cr "${STAGED_APP}" || true

if [[ -d "${DEST_APP}" ]]; then
  echo "[install] removing existing install..."
  chmod -R u+w "${DEST_APP}" 2>/dev/null || true
  if ! rm -rf "${DEST_APP}" 2>/dev/null; then
    echo "[install] unable to remove existing app at ${DEST_APP}"
    echo "[install] check permissions and remove it manually, then re-run this script."
    exit 1
  fi
fi

echo "[install] promoting staged app into ~/Applications..."
mv "${STAGED_APP}" "${DEST_APP}"

echo "[install] verifying signature..."
if ! codesign --verify --strict "${DEST_APP}" >/dev/null 2>&1; then
  echo "[install] error: codesign verification failed after install."
  exit 1
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
