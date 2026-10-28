#!/bin/sh
set -eu

# Usage: package-dmg.sh
#
# Builds the app in Release, bundles the core from the sibling DJOneHub
# checkout (its release build, which carries the official libusb rather than
# Homebrew's), signs ad hoc and wraps it in a dmg with an Applications link.
# arm64 only: that is the only core build verified on hardware.

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_DIR="${ROOT_DIR}/../DJOneHub"
APP_NAME="DJI 4G Module"
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "${ROOT_DIR}/project.yml")
BUILT_APP="${ROOT_DIR}/build/Build/Products/Release/${APP_NAME}.app"
STAGE="${ROOT_DIR}/build/dmg"
DMG="${ROOT_DIR}/build/DJI-4G-Module-${VERSION}-arm64.dmg"

if [ ! -x "${CORE_DIR}/scripts/package-macos.sh" ]; then
  echo "DJOneHub checkout not found next to this one: ${CORE_DIR}" >&2
  exit 1
fi

cd "${ROOT_DIR}"
xcodegen generate >/dev/null
xcodebuild -project DJOneHub.xcodeproj -scheme DJOneHub -configuration Release \
  -derivedDataPath build build >/dev/null

"${CORE_DIR}/scripts/package-macos.sh" "v${VERSION}" arm64 >/dev/null
CORE_RELEASE="${CORE_DIR}/dist/release/DJOneHub-macOS-arm64-v${VERSION}"

rm -rf "${STAGE}"
mkdir -p "${STAGE}"
APP="${STAGE}/${APP_NAME}.app"
cp -R "${BUILT_APP}" "${APP}"

# CoreLocator looks for the core among the app's resources. The core finds
# libusb at @executable_path/../lib, which inside a bundle would be an unsealable
# Contents/lib, so the dylib goes to Frameworks and the core is pointed there.
cp "${CORE_RELEASE}/bin/djonehub-macos" "${APP}/Contents/Resources/djonehub-macos"
mkdir -p "${APP}/Contents/Frameworks"
cp "${CORE_RELEASE}/lib/libusb-1.0.0.dylib" "${APP}/Contents/Frameworks/"
install_name_tool -change @executable_path/../lib/libusb-1.0.0.dylib \
  @executable_path/../Frameworks/libusb-1.0.0.dylib \
  "${APP}/Contents/Resources/djonehub-macos"
mkdir -p "${APP}/Contents/Resources/licenses"
cp "${CORE_RELEASE}/LICENSE" "${CORE_RELEASE}/THIRD_PARTY_NOTICES.md" \
  "${CORE_RELEASE}"/licenses/* "${APP}/Contents/Resources/licenses/"

# Inside out: a signature covers what is nested in it, so the app goes last.
codesign --force --sign - "${APP}/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --sign - "${APP}/Contents/Resources/djonehub-macos"
codesign --force --sign - "${APP}"
codesign --verify --strict "${APP}"

ln -s /Applications "${STAGE}/Applications"
rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -format UDZO -ov "${DMG}" >/dev/null
echo "${DMG}"
