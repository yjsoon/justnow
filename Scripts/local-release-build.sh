#!/usr/bin/env bash
set -euo pipefail

SCHEME="${SCHEME:-JustNow}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build}"
VERSION="local"
APP_NAME="${SCHEME}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
ZIP_PATH="dist/${APP_NAME}-${VERSION}-macos.zip"
DMG_PATH="dist/${APP_NAME}-${VERSION}-macos.dmg"
STAGING_DIR="dist/staging"
BG_PATH="Assets/Release/dmg-background.png"
USE_DISTRIBUTION_SIGNING="${USE_DISTRIBUTION_SIGNING:-false}"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}"
VERSION_SET="false"

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/local-release-build.sh [version] [--distribution] [--identity "Developer ID Application: Name (TEAMID)"] [--team TEAMID]

Options:
  [version]     Optional artifact version suffix (default: local)
  --distribution    Sign app and DMG with Developer ID credentials
  --identity        Developer ID identity for signing
  --team            Developer ID development team ID
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distribution|--release|--sign)
      USE_DISTRIBUTION_SIGNING="true"
      shift
      ;;
    --identity)
      [[ -n "${2:-}" ]] || { echo "--identity requires a value"; usage; exit 1; }
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --team)
      [[ -n "${2:-}" ]] || { echo "--team requires a value"; usage; exit 1; }
      DEVELOPMENT_TEAM="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [ "${VERSION_SET}" = "false" ]; then
        VERSION="$1"
        VERSION_SET="true"
        shift
      else
        echo "Unexpected extra argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

ZIP_PATH="dist/${APP_NAME}-${VERSION}-macos.zip"
DMG_PATH="dist/${APP_NAME}-${VERSION}-macos.dmg"

mkdir -p dist
mkdir -p "${STAGING_DIR}"
rm -rf "${STAGING_DIR:?}"/*

echo "Using macOS SDK: $(xcrun --sdk macosx --show-sdk-version)"
XCODEBUILD_CMD=(xcodebuild -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -derivedDataPath "${DERIVED_DATA_PATH}")

if [ "${USE_DISTRIBUTION_SIGNING}" = "true" ]; then
  if [ -z "${SIGNING_IDENTITY}" ] || [ -z "${DEVELOPMENT_TEAM}" ]; then
    echo "Distribution signing requested, but identity/team are missing."
    usage
    exit 1
  fi

  XCODEBUILD_CMD+=(
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}"
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}"
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGNING_ALLOWED=YES
  )
fi

"${XCODEBUILD_CMD[@]}"

cp -R "${APP_PATH}" "${STAGING_DIR}/"
rm -f "${ZIP_PATH}" "${DMG_PATH}"

ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

if command -v create-dmg >/dev/null 2>&1; then
  if [ -f "${BG_PATH}" ]; then
    create-dmg \
      --window-pos 200 120 \
      --window-size 560 360 \
      --icon-size 120 \
      --text-size 12 \
      --icon "${APP_NAME}.app" 160 190 \
      --app-drop-link 390 190 \
      --hide-extension "${APP_NAME}.app" \
      --no-internet-enable \
      --volname "${APP_NAME} ${VERSION}" \
      --background "${BG_PATH}" \
      "${DMG_PATH}" \
      "${STAGING_DIR}/"
  else
    create-dmg \
      --window-pos 200 120 \
      --window-size 560 360 \
      --icon-size 120 \
      --text-size 12 \
      --icon "${APP_NAME}.app" 160 190 \
      --app-drop-link 390 190 \
      --hide-extension "${APP_NAME}.app" \
      --no-internet-enable \
      --volname "${APP_NAME} ${VERSION}" \
      "${DMG_PATH}" \
      "${STAGING_DIR}/"
  fi
else
  echo "create-dmg not found; skipping .dmg creation. Install with: brew install create-dmg"
fi

if [ "${USE_DISTRIBUTION_SIGNING}" = "true" ]; then
  echo "Signing distribution artifacts with ${SIGNING_IDENTITY}"
  codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${APP_PATH}"
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
  if [ -f "${DMG_PATH}" ]; then
    codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"
    codesign --verify --strict --verbose=2 "${DMG_PATH}"
  fi
fi

rm -rf "${STAGING_DIR}"
echo "Built:"
echo "  - ${ZIP_PATH}"
if [ -f "${DMG_PATH}" ]; then
  echo "  - ${DMG_PATH}"
fi
