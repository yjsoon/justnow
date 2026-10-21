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
EXPECTED_BUNDLE_ID="sg.tk.JustNow"
ALLOW_SIGNING_CHANGE="false"

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/local-install-app.sh [version] [--notarize] [--identity "Developer ID Application: Name (TEAMID)"] [--team TEAMID] [--api-key /path/to/AuthKey.p8] [--api-key-id KEYID] [--api-issuer ISSUER-UUID] [--allow-signing-change]

This helper keeps local installs at /Applications/JustNow.app and prefers a stable
Developer ID signature so macOS can keep the same Screen Recording permission record.

Before stopping or replacing an existing Developer ID install, it verifies the new
build's signature and bundle identifier, and refuses if its Team ID or designated
requirement no longer matches the installed app.

  --allow-signing-change  Intentionally migrate the install to a different signing
                          identity or mode. macOS will likely ask for Screen Recording
                          permission again. It skips only the comparisons with the
                          installed app; signature, bundle ID and team consistency
                          checks still apply.
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

  { codesign -dv --verbose=4 "${INSTALL_PATH}" 2>&1 || true; } | sed -n 's/^Authority=//p' | head -n 1
}

team_from_identity() {
  local identity="$1"
  sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' <<<"${identity}"
}

signing_field() {
  local path="$1" field="$2"
  { codesign -dv --verbose=4 "${path}" 2>&1 || true; } | sed -n "s/^${field}=//p" | head -n 1
}

designated_requirement() {
  { codesign -d -r- "$1" 2>&1 || true; } | sed -n 's/^designated => //p' | head -n 1
}

# Returns 0 if the built app satisfies the installed app's designated requirement,
# 1 if it does not, and stops the script on any other codesign error.
satisfies_installed_requirement() {
  local output status=0
  output="$(codesign --verify -R "=${INSTALLED_REQUIREMENT}" "${APP_PATH}" 2>&1)" || status=$?
  case "${status}" in
    0) return 0 ;;
    3) return 1 ;;
    *) die "codesign could not test ${APP_PATH} against the installed app's designated requirement (exit ${status}):
${output}" ;;
  esac
}

bundle_identifier() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

refuse_signing_change() {
  cat >&2 <<EOF
Refusing to replace ${INSTALL_PATH}: $1

Replacing it would change the app's code-signing identity, so macOS would treat it
as a different app and ask for Screen Recording permission again. Nothing has been
stopped or removed.

Use the identity that signed the installed app, or rerun with --allow-signing-change
if you are deliberately migrating to a new signing identity.
EOF
  exit 1
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
    --allow-signing-change)
      ALLOW_SIGNING_CHANGE="true"
      shift
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

if [ -n "${SIGNING_IDENTITY}" ] && [ -n "${DEVELOPMENT_TEAM}" ]; then
  IDENTITY_TEAM="$(team_from_identity "${SIGNING_IDENTITY}")"
  if [ -n "${IDENTITY_TEAM}" ] && [ "${IDENTITY_TEAM}" != "${DEVELOPMENT_TEAM}" ]; then
    die "Team ${DEVELOPMENT_TEAM} does not match the signing identity's team ${IDENTITY_TEAM} (${SIGNING_IDENTITY}). Fix APPLE_SIGNING_IDENTITY/APPLE_TEAM_ID or the --identity/--team arguments."
  fi
fi

INSTALLED_IS_DEVELOPER_ID="false"
INSTALLED_TEAM=""
INSTALLED_REQUIREMENT=""
if [[ "${INSTALLED_AUTHORITY}" == Developer\ ID\ Application:* ]]; then
  INSTALLED_IS_DEVELOPER_ID="true"
  INSTALLED_TEAM="$(signing_field "${INSTALL_PATH}" TeamIdentifier)"
  INSTALLED_REQUIREMENT="$(designated_requirement "${INSTALL_PATH}")"
  INSTALLED_BUNDLE_ID="$(bundle_identifier "${INSTALL_PATH}")"
  [ "${INSTALLED_BUNDLE_ID}" = "${EXPECTED_BUNDLE_ID}" ] || die "The installed ${INSTALL_PATH} has bundle identifier '${INSTALLED_BUNDLE_ID}', expected '${EXPECTED_BUNDLE_ID}'. Move it aside yourself if it should be replaced. Nothing was changed."
  if [ "${ALLOW_SIGNING_CHANGE}" != "true" ]; then
    if [ -z "${INSTALLED_TEAM}" ] || [ "${INSTALLED_TEAM}" = "not set" ] || [ -z "${INSTALLED_REQUIREMENT}" ]; then
      refuse_signing_change "could not read the installed app's Team ID or designated requirement."
    fi
    if [ -n "${DEVELOPMENT_TEAM}" ] && [ "${DEVELOPMENT_TEAM}" != "${INSTALLED_TEAM}" ]; then
      refuse_signing_change "the configured team ${DEVELOPMENT_TEAM} differs from the installed app's team ${INSTALLED_TEAM}."
    fi
  fi
fi

if [ "${USE_NOTARIZATION}" = "true" ]; then
  [ -n "${SIGNING_IDENTITY}" ] || die "Notarisation requires a Developer ID signing identity. Set APPLE_SIGNING_IDENTITY in ${RELEASE_ENV_FILE}, or pass --identity explicitly."
  [ -n "${DEVELOPMENT_TEAM}" ] || die "Notarisation requires a Developer ID team. Set APPLE_TEAM_ID in ${RELEASE_ENV_FILE}, or pass --team explicitly."
  [ -n "${API_KEY_PATH}" ] || die "Notarisation requires an App Store Connect API key path. Set APPLE_API_KEY_PATH in ${RELEASE_ENV_FILE}, or pass --api-key explicitly."
  [ -n "${API_KEY_ID}" ] || die "Notarisation requires an App Store Connect API key ID. Set APPLE_API_KEY_ID in ${RELEASE_ENV_FILE}, or pass --api-key-id explicitly."
  [ -f "${API_KEY_PATH}" ] || die "App Store Connect API key not found at: ${API_KEY_PATH}"
fi

if [ -z "${SIGNING_IDENTITY}" ] || [ -z "${DEVELOPMENT_TEAM}" ]; then
  if [ "${INSTALLED_IS_DEVELOPER_ID}" = "true" ] && [ "${ALLOW_SIGNING_CHANGE}" != "true" ]; then
    cat >&2 <<EOF
Refusing to replace the existing Developer ID-signed ${INSTALL_PATH} with a different signing mode.

Set APPLE_SIGNING_IDENTITY and APPLE_TEAM_ID in ${RELEASE_ENV_FILE}, or pass --identity and --team explicitly.
This keeps Screen Recording permission attached to the same app identity.
Pass --allow-signing-change only if you deliberately want to leave Developer ID signing.
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

# Everything below must pass before the running app is stopped or the install is touched.
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" || die "The built app at ${APP_PATH} failed signature verification. Nothing was installed."

BUILT_BUNDLE_ID="$(bundle_identifier "${APP_PATH}")"
[ "${BUILT_BUNDLE_ID}" = "${EXPECTED_BUNDLE_ID}" ] || die "The built app's bundle identifier is '${BUILT_BUNDLE_ID}', expected '${EXPECTED_BUNDLE_ID}'. Nothing was installed."

BUILT_TEAM="$(signing_field "${APP_PATH}" TeamIdentifier)"
if [ -n "${SIGNING_IDENTITY}" ] && [ -n "${DEVELOPMENT_TEAM}" ] && [ "${BUILT_TEAM}" != "${DEVELOPMENT_TEAM}" ]; then
  die "The built app is signed by team '${BUILT_TEAM}', but team ${DEVELOPMENT_TEAM} was configured. Nothing was installed."
fi

if [ "${INSTALLED_IS_DEVELOPER_ID}" = "true" ]; then
  if [ "${ALLOW_SIGNING_CHANGE}" = "true" ]; then
    if [ "${BUILT_TEAM}" != "${INSTALLED_TEAM}" ] || [ -z "${INSTALLED_REQUIREMENT}" ] || ! satisfies_installed_requirement; then
      echo "--allow-signing-change: replacing the installed signing identity. macOS will likely ask for Screen Recording permission again." >&2
    fi
  else
    if [ "${BUILT_TEAM}" != "${INSTALLED_TEAM}" ]; then
      refuse_signing_change "the new build's team '${BUILT_TEAM}' differs from the installed app's team ${INSTALLED_TEAM}."
    fi
    # TCC matches apps by their designated requirement, so the new build must satisfy the installed one.
    if ! satisfies_installed_requirement; then
      refuse_signing_change "the new build does not satisfy the installed app's designated requirement:
  ${INSTALLED_REQUIREMENT}"
    fi
  fi
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
