#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="${APP_NAME:-extend_screen}"
SCHEME="${SCHEME:-extend_screen}"
CONFIGURATION="${CONFIGURATION:-Release}"
VOLUME_NAME="${VOLUME_NAME:-ESP USB Display}"
PROJECT_PATH="${PROJECT_PATH:-${PROJECT_ROOT}/extend_screen.xcodeproj}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${PROJECT_ROOT}/build/package}"
DIST_DIR="${DIST_DIR:-${PROJECT_ROOT}/dist}"

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
DMG_ROOT="${DIST_DIR}/dmg-root"
DMG_PATH="${DIST_DIR}/ESP_USB_Display_unsigned.dmg"

echo "==> Building ${APP_NAME} (${CONFIGURATION})"
xcodebuild \
  -quiet \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "==> Ad-hoc signing ${APP_PATH}"
codesign --force --deep --sign - "${APP_PATH}"
codesign --verify --deep --verbose=2 "${APP_PATH}"

echo "==> Preparing DMG root"
rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}" "${DIST_DIR}"
ditto "${APP_PATH}" "${DMG_ROOT}/${APP_NAME}.app"
ln -s /Applications "${DMG_ROOT}/Applications"

echo "==> Creating ${DMG_PATH}"
rm -f "${DMG_PATH}"
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "==> Done"
echo "${DMG_PATH}"
