#!/usr/bin/env bash
set -euo pipefail

RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-.env.release.local}"
if [ -f "${RELEASE_ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${RELEASE_ENV_FILE}"
  set +a
fi

SCHEME="${SCHEME:-JustNow}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build}"
VERSION="local"
APP_NAME="${SCHEME}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
APP_EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${APP_NAME}"
ZIP_PATH="dist/${APP_NAME}-${VERSION}-macos.zip"
DMG_PATH="dist/${APP_NAME}-${VERSION}-macos.dmg"
STAGING_DIR="dist/staging"
BG_PATH="Assets/Release/dmg-background.png"
ENTITLEMENTS_PATH="Scripts/distribution-entitlements.plist"
APPLICATIONS_ALIAS_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
USE_DISTRIBUTION_SIGNING="${USE_DISTRIBUTION_SIGNING:-false}"
USE_NOTARIZATION="${USE_NOTARIZATION:-false}"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}"
API_KEY_PATH="${APPLE_API_KEY_PATH:-}"
API_KEY_ID="${APPLE_API_KEY_ID:-}"
API_ISSUER_ID="${APPLE_API_KEY_ISSUER_ID:-}"
VERSION_SET="false"

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/local-release-build.sh [version] [--distribution] [--notarize] [--identity "Developer ID Application: Name (TEAMID)"] [--team TEAMID] [--api-key /path/to/AuthKey.p8] [--api-key-id KEYID] [--api-issuer ISSUER-UUID]

Options:
  [version]     Optional artifact version suffix (default: local)
  --distribution    Sign app and DMG with Developer ID credentials
  --notarize        Submit the signed DMG for notarisation and staple the result
  --identity        Developer ID identity for signing
  --team            Developer ID development team ID
  --api-key         Path to an App Store Connect API key (.p8)
  --api-key-id      App Store Connect API key ID
  --api-issuer      App Store Connect issuer ID (omit for Individual API keys)
EOF
}

sign_sparkle_support_binaries() {
  local app_bundle_path="$1"
  local framework_path="${app_bundle_path}/Contents/Frameworks/Sparkle.framework"
  local version_path="${framework_path}/Versions/B"

  if [ ! -d "${framework_path}" ]; then
    return
  fi

  local updater_app="${version_path}/Updater.app"
  local downloader_xpc="${version_path}/XPCServices/Downloader.xpc"
  local installer_xpc="${version_path}/XPCServices/Installer.xpc"
  local autoupdate_binary="${version_path}/Autoupdate"

  if [ -e "${autoupdate_binary}" ]; then
    codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${autoupdate_binary}"
  fi

  for nested_bundle in "${downloader_xpc}" "${installer_xpc}" "${updater_app}"; do
    if [ -d "${nested_bundle}" ]; then
      codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${nested_bundle}"
    fi
  done

  codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${version_path}"
  codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${framework_path}"
}

create_applications_alias() {
  local target_dir="$1"
  local alias_path="${target_dir}/Applications"
  local icon_copy_base
  local icon_resource

  for tool in osascript sips DeRez Rez SetFile; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "Missing required tool for DMG Applications alias: ${tool}" >&2
      exit 1
    fi
  done

  if [ ! -f "${APPLICATIONS_ALIAS_ICON}" ]; then
    echo "Applications folder icon not found at: ${APPLICATIONS_ALIAS_ICON}" >&2
    exit 1
  fi

  osascript - "${target_dir}" <<'APPLESCRIPT'
on run argv
  set targetDir to item 1 of argv
  tell application "Finder"
    set targetFolder to POSIX file targetDir as alias
    set aliasFile to make new alias file at targetFolder to POSIX file "/Applications"
    set name of aliasFile to "Applications"
  end tell
end run
APPLESCRIPT

  icon_copy_base="$(mktemp "${TMPDIR:-/tmp}/applications-folder-icon.XXXXXX")"
  cp "${APPLICATIONS_ALIAS_ICON}" "${icon_copy_base}.icns"
  sips -i "${icon_copy_base}.icns" >/dev/null

  icon_resource="$(mktemp "${TMPDIR:-/tmp}/applications-folder-icon-rsrc.XXXXXX")"
  DeRez -only icns "${icon_copy_base}.icns" > "${icon_resource}"
  Rez -append "${icon_resource}" -o "${alias_path}"
  SetFile -a C "${alias_path}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distribution|--release|--sign)
      USE_DISTRIBUTION_SIGNING="true"
      shift
      ;;
    --notarize|--notarise)
      USE_NOTARIZATION="true"
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
    --api-key)
      [[ -n "${2:-}" ]] || { echo "--api-key requires a value"; usage; exit 1; }
      API_KEY_PATH="$2"
      shift 2
      ;;
    --api-key-id)
      [[ -n "${2:-}" ]] || { echo "--api-key-id requires a value"; usage; exit 1; }
      API_KEY_ID="$2"
      shift 2
      ;;
    --api-issuer)
      [[ -n "${2:-}" ]] || { echo "--api-issuer requires a value"; usage; exit 1; }
      API_ISSUER_ID="$2"
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
APP_ICON_X=160
APP_ICON_Y=190
APPS_ICON_X=390
APPS_ICON_Y=190

if [ "${USE_NOTARIZATION}" = "true" ]; then
  if [ -z "${API_KEY_PATH}" ] || [ -z "${API_KEY_ID}" ]; then
    echo "Notarisation requested, but App Store Connect API key details are missing."
    usage
    exit 1
  fi
  if [ ! -f "${API_KEY_PATH}" ]; then
    echo "App Store Connect API key not found at: ${API_KEY_PATH}"
    exit 1
  fi
fi

./Scripts/generate-appicon-icns.sh
XCODEBUILD_CMD=(xcodebuild -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -derivedDataPath "${DERIVED_DATA_PATH}")

if [ "${USE_DISTRIBUTION_SIGNING}" = "true" ]; then
  if [ -z "${SIGNING_IDENTITY}" ] || [ -z "${DEVELOPMENT_TEAM}" ]; then
    echo "Distribution signing requested, but identity/team are missing."
    usage
    exit 1
  fi

  XCODEBUILD_CMD+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
  )
fi

"${XCODEBUILD_CMD[@]}"

rm -f "${ZIP_PATH}" "${DMG_PATH}"

if [ "${USE_DISTRIBUTION_SIGNING}" = "true" ]; then
  echo "Signing distribution artifacts with ${SIGNING_IDENTITY}"
  codesign --force --options runtime --timestamp --entitlements "${ENTITLEMENTS_PATH}" --sign "${SIGNING_IDENTITY}" "${APP_EXECUTABLE_PATH}"
  sign_sparkle_support_binaries "${APP_PATH}"
  codesign --force --options runtime --timestamp --entitlements "${ENTITLEMENTS_PATH}" --sign "${SIGNING_IDENTITY}" "${APP_PATH}"
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
fi

mkdir -p "${STAGING_DIR}"
rm -rf "${STAGING_DIR:?}"/*
cp -R "${APP_PATH}" "${STAGING_DIR}/"
create_applications_alias "${STAGING_DIR}"

ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

if command -v create-dmg >/dev/null 2>&1; then
  if [ -f "${BG_PATH}" ]; then
    create-dmg \
      --window-pos 200 120 \
      --window-size 560 360 \
      --icon-size 120 \
      --text-size 12 \
      --icon "${APP_NAME}.app" "${APP_ICON_X}" "${APP_ICON_Y}" \
      --icon "Applications" "${APPS_ICON_X}" "${APPS_ICON_Y}" \
      --hide-extension "${APP_NAME}.app" \
      --no-internet-enable \
      --volname "${APP_NAME}" \
      --background "${BG_PATH}" \
      "${DMG_PATH}" \
      "${STAGING_DIR}/"
  else
    create-dmg \
      --window-pos 200 120 \
      --window-size 560 360 \
      --icon-size 120 \
      --text-size 12 \
      --icon "${APP_NAME}.app" "${APP_ICON_X}" "${APP_ICON_Y}" \
      --icon "Applications" "${APPS_ICON_X}" "${APPS_ICON_Y}" \
      --hide-extension "${APP_NAME}.app" \
      --no-internet-enable \
      --volname "${APP_NAME}" \
      "${DMG_PATH}" \
      "${STAGING_DIR}/"
  fi
else
  echo "create-dmg not found; skipping .dmg creation. Install with: brew install create-dmg"
fi

if [ "${USE_DISTRIBUTION_SIGNING}" = "true" ] && [ -f "${DMG_PATH}" ]; then
  codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"
  codesign --verify --strict --verbose=2 "${DMG_PATH}"
fi

if [ "${USE_NOTARIZATION}" = "true" ] && [ -f "${DMG_PATH}" ]; then
  NOTARY_CMD=(
    xcrun notarytool submit "${DMG_PATH}"
    --key "${API_KEY_PATH}"
    --key-id "${API_KEY_ID}"
    --team-id "${DEVELOPMENT_TEAM}"
    --wait
  )

  if [ -n "${API_ISSUER_ID}" ]; then
    NOTARY_CMD+=(--issuer "${API_ISSUER_ID}")
  fi

  "${NOTARY_CMD[@]}"
  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler validate "${DMG_PATH}"
fi

rm -rf "${STAGING_DIR}"
echo "Built:"
echo "  - ${ZIP_PATH}"
if [ -f "${DMG_PATH}" ]; then
  echo "  - ${DMG_PATH}"
fi
