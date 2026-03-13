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
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${SCHEME}.app"
INSTALL_PATH="/Applications/${SCHEME}.app"
VERSION="local"
VERSION_SET="false"
USE_NOTARIZATION="false"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}"
API_KEY_PATH="${APPLE_API_KEY_PATH:-}"
API_KEY_ID="${APPLE_API_KEY_ID:-}"
API_ISSUER_ID="${APPLE_API_KEY_ISSUER_ID:-}"

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/local-install-app.sh [version] [--notarize] [--identity "Developer ID Application: Name (TEAMID)"] [--team TEAMID] [--api-key /path/to/AuthKey.p8] [--api-key-id KEYID] [--api-issuer ISSUER-UUID]

This helper keeps local installs at /Applications/JustNow.app and prefers a stable
Developer ID signature so macOS can keep the same Screen Recording permission record.
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

installed_leaf_authority() {
  if [ ! -e "${INSTALL_PATH}" ]; then
    return 0
  fi

  codesign -dv --verbose=4 "${INSTALL_PATH}" 2>&1 | sed -n 's/^Authority=//p' | head -n 1
}

team_from_identity() {
  local identity="$1"
  sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' <<<"${identity}"
}

discover_developer_identities() {
  security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize|--notarise)
      USE_NOTARIZATION="true"
      shift
      ;;
    --identity)
      [[ -n "${2:-}" ]] || { echo "--identity requires a value" >&2; usage; exit 1; }
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --team)
      [[ -n "${2:-}" ]] || { echo "--team requires a value" >&2; usage; exit 1; }
      DEVELOPMENT_TEAM="$2"
      shift 2
      ;;
    --api-key)
      [[ -n "${2:-}" ]] || { echo "--api-key requires a value" >&2; usage; exit 1; }
      API_KEY_PATH="$2"
      shift 2
      ;;
    --api-key-id)
      [[ -n "${2:-}" ]] || { echo "--api-key-id requires a value" >&2; usage; exit 1; }
      API_KEY_ID="$2"
      shift 2
      ;;
    --api-issuer)
      [[ -n "${2:-}" ]] || { echo "--api-issuer requires a value" >&2; usage; exit 1; }
      API_ISSUER_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ "${VERSION_SET}" = "false" ]; then
        VERSION="$1"
        VERSION_SET="true"
        shift
      else
        echo "Unknown argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

INSTALLED_AUTHORITY="$(installed_leaf_authority)"

if [ -z "${SIGNING_IDENTITY}" ]; then
  developer_identities=()
  while IFS= read -r identity; do
    [ -n "${identity}" ] || continue
    developer_identities+=("${identity}")
  done < <(discover_developer_identities)

  if [ "${#developer_identities[@]}" -eq 1 ]; then
    SIGNING_IDENTITY="${developer_identities[0]}"
  elif [ "${#developer_identities[@]}" -gt 1 ] && [ -n "${INSTALLED_AUTHORITY}" ]; then
    for identity in "${developer_identities[@]}"; do
      if [ "${identity}" = "${INSTALLED_AUTHORITY}" ]; then
        SIGNING_IDENTITY="${identity}"
        break
      fi
    done
  fi
fi

if [ -n "${SIGNING_IDENTITY}" ] && [ -z "${DEVELOPMENT_TEAM}" ]; then
  DEVELOPMENT_TEAM="$(team_from_identity "${SIGNING_IDENTITY}")"
fi

if [ "${USE_NOTARIZATION}" = "true" ]; then
  [ -n "${SIGNING_IDENTITY}" ] || die "Notarisation requires a Developer ID signing identity. Set APPLE_SIGNING_IDENTITY in ${RELEASE_ENV_FILE}, or pass --identity explicitly."
  [ -n "${DEVELOPMENT_TEAM}" ] || die "Notarisation requires a Developer ID team. Set APPLE_TEAM_ID in ${RELEASE_ENV_FILE}, or pass --team explicitly."
  [ -n "${API_KEY_PATH}" ] || die "Notarisation requires an App Store Connect API key path. Set APPLE_API_KEY_PATH in ${RELEASE_ENV_FILE}, or pass --api-key explicitly."
  [ -n "${API_KEY_ID}" ] || die "Notarisation requires an App Store Connect API key ID. Set APPLE_API_KEY_ID in ${RELEASE_ENV_FILE}, or pass --api-key-id explicitly."
  [ -f "${API_KEY_PATH}" ] || die "App Store Connect API key not found at: ${API_KEY_PATH}"
fi

if [ -z "${SIGNING_IDENTITY}" ] || [ -z "${DEVELOPMENT_TEAM}" ]; then
  if [[ "${INSTALLED_AUTHORITY}" == Developer\ ID\ Application:* ]]; then
    cat >&2 <<EOF
Refusing to replace the existing Developer ID-signed ${INSTALL_PATH} with a different signing mode.

Set APPLE_SIGNING_IDENTITY and APPLE_TEAM_ID in ${RELEASE_ENV_FILE}, or pass --identity and --team explicitly.
This keeps Screen Recording permission attached to the same app identity.
EOF
    exit 1
  fi

  echo "No Developer ID identity configured; falling back to Xcode's default signing." >&2
  echo "If you later switch this install to a Developer ID build, macOS may ask for Screen Recording permission again." >&2
  xcodebuild -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -derivedDataPath "${DERIVED_DATA_PATH}"
else
  BUILD_CMD=(./Scripts/local-release-build.sh "${VERSION}" --distribution --identity "${SIGNING_IDENTITY}" --team "${DEVELOPMENT_TEAM}")
  if [ "${USE_NOTARIZATION}" = "true" ]; then
    BUILD_CMD+=(--notarize --api-key "${API_KEY_PATH}" --api-key-id "${API_KEY_ID}")
    if [ -n "${API_ISSUER_ID}" ]; then
      BUILD_CMD+=(--api-issuer "${API_ISSUER_ID}")
    fi
  fi
  "${BUILD_CMD[@]}"
fi

if [ ! -d "${APP_PATH}" ]; then
  echo "Built app not found at ${APP_PATH}" >&2
  exit 1
fi

[ -x "$(command -v trash)" ] || die "The 'trash' CLI is required to replace ${INSTALL_PATH} safely. Install it first, then rerun this helper."

pkill -x "${SCHEME}" 2>/dev/null || true
if [ -e "${INSTALL_PATH}" ]; then
  trash "${INSTALL_PATH}"
fi

cp -R "${APP_PATH}" /Applications/
open "${INSTALL_PATH}" || echo "open failed; launch ${INSTALL_PATH} manually." >&2

echo "Installed ${INSTALL_PATH}"
codesign -dv --verbose=4 "${INSTALL_PATH}" 2>&1 | sed -n 's/^Identifier=/Identifier: /p; s/^Authority=/Authority: /p' | head -n 4
