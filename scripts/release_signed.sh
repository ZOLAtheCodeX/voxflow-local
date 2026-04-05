#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${ROOT_DIR}/dist/VoxFlow.app"
ENTITLEMENTS_PATH="${ROOT_DIR}/scripts/release/VoxFlow.entitlements"
OUT_DIR="${ROOT_DIR}/dist/release"

VERSION=""
IDENTITY=""
TEAM_ID=""
NOTARY_PROFILE=""

usage() {
  cat <<EOF
Usage:
  $0 --version <semver> --identity "<Developer ID Application: ...>" --team-id <TEAMID> --notary-profile <profile>

Example:
  $0 --version 0.2.0 \\
     --identity "Developer ID Application: Example, Inc. (ABCDE12345)" \\
     --team-id ABCDE12345 \\
     --notary-profile voxflow-notary
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --team-id)
      TEAM_ID="${2:-}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[release] unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${VERSION}" || -z "${IDENTITY}" || -z "${TEAM_ID}" || -z "${NOTARY_PROFILE}" ]]; then
  echo "[release] missing required arguments"
  usage
  exit 1
fi

for cmd in swift codesign xcrun hdiutil ditto; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[release] required command not found: ${cmd}"
    exit 1
  fi
done

if [[ ! -f "${ENTITLEMENTS_PATH}" ]]; then
  echo "[release] missing entitlements file: ${ENTITLEMENTS_PATH}"
  exit 1
fi

echo "[release] building release app bundle..."
"${ROOT_DIR}/scripts/build_app_bundle.sh" --release

if [[ ! -d "${APP_PATH}" ]]; then
  echo "[release] missing app bundle: ${APP_PATH}"
  exit 1
fi

if ! grep -q "${TEAM_ID}" <<<"${IDENTITY}"; then
  echo "[release] warning: identity does not appear to contain team id ${TEAM_ID}"
fi

echo "[release] signing app with hardened runtime..."
codesign --force --deep --options runtime --timestamp \
  --entitlements "${ENTITLEMENTS_PATH}" \
  --sign "${IDENTITY}" \
  "${APP_PATH}"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

VERSION_OUT="${OUT_DIR}/v${VERSION}"
rm -rf "${VERSION_OUT}"
mkdir -p "${VERSION_OUT}"

APP_ARCHIVE="${VERSION_OUT}/VoxFlow.app"
DMG_PATH="${VERSION_OUT}/VoxFlow-${VERSION}.dmg"
ZIP_PATH="${VERSION_OUT}/VoxFlow-${VERSION}.zip"
CHECKSUM_PATH="${VERSION_OUT}/checksums.txt"

ditto "${APP_PATH}" "${APP_ARCHIVE}"

echo "[release] creating DMG..."
hdiutil create -volname "VoxFlow" -srcfolder "${APP_ARCHIVE}" -ov -format UDZO "${DMG_PATH}" >/dev/null

echo "[release] notarizing DMG..."
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait

echo "[release] stapling notarization..."
xcrun stapler staple "${APP_ARCHIVE}"
xcrun stapler staple "${DMG_PATH}"

echo "[release] creating ZIP from stapled archive..."
ditto -c -k --sequesterRsrc --keepParent "${APP_ARCHIVE}" "${ZIP_PATH}"

echo "[release] writing checksums..."
(cd "${VERSION_OUT}" && shasum -a 256 "$(basename "${DMG_PATH}")" "$(basename "${ZIP_PATH}")" > "${CHECKSUM_PATH}")

echo "[release] done"
echo "  app: ${APP_ARCHIVE}"
echo "  dmg: ${DMG_PATH}"
echo "  zip: ${ZIP_PATH}"
echo "  checksums: ${CHECKSUM_PATH}"
