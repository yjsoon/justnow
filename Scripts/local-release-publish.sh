#!/usr/bin/env bash
set -euo pipefail

RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-.env.release.local}"
if [ -f "${RELEASE_ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${RELEASE_ENV_FILE}"
  set +a
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/sparkle-config.sh"

TAG=""
TITLE=""
NOTES_FILE=""
DRAFT="false"
PRERELEASE="false"
SKIP_BUILD="false"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}"
API_KEY_PATH="${APPLE_API_KEY_PATH:-}"
API_KEY_ID="${APPLE_API_KEY_ID:-}"
API_ISSUER_ID="${APPLE_API_KEY_ISSUER_ID:-}"
PROJECT_FILE="JustNow.xcodeproj/project.pbxproj"

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/local-release-publish.sh <tag> [options]

Options:
  <tag>              Existing Git tag to publish, for example: v0.1.1
  --title <title>    Release title (default: tag)
  --notes-file <f>   Use a release notes file instead of GitHub generated notes
  --draft            Create or keep the GitHub release as a draft
  --prerelease       Mark the GitHub release as a prerelease
  --skip-build       Upload existing dist artifacts without rebuilding
  --identity <name>  Developer ID identity for signing
  --team <id>        Developer Team ID
  --api-key <path>   App Store Connect API key (.p8) path
  --api-key-id <id>  App Store Connect API key ID
  --api-issuer <id>  App Store Connect issuer ID (omit for Individual keys)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      [[ -n "${2:-}" ]] || { echo "--title requires a value"; usage; exit 1; }
      TITLE="$2"
      shift 2
      ;;
    --notes-file)
      [[ -n "${2:-}" ]] || { echo "--notes-file requires a value"; usage; exit 1; }
      NOTES_FILE="$2"
      shift 2
      ;;
    --draft)
      DRAFT="true"
      shift
      ;;
    --prerelease)
      PRERELEASE="true"
      shift
      ;;
    --skip-build)
      SKIP_BUILD="true"
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
      if [ -z "${TAG}" ]; then
        TAG="$1"
        shift
      else
        echo "Unexpected extra argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

if [ -z "${TAG}" ]; then
  usage
  exit 1
fi

if [ -z "${TITLE}" ]; then
  TITLE="${TAG}"
fi

if [ ! -f "${PROJECT_FILE}" ]; then
  echo "Could not find Xcode project file at ${PROJECT_FILE}"
  exit 1
fi

MARKETING_VERSIONS="$(rg -o 'MARKETING_VERSION = [^;]+' "${PROJECT_FILE}" | sed 's/.*= //' | sort -u)"
CURRENT_PROJECT_VERSIONS="$(rg -o 'CURRENT_PROJECT_VERSION = [^;]+' "${PROJECT_FILE}" | sed 's/.*= //' | sort -u)"
MARKETING_VERSION_COUNT="$(printf '%s\n' "${MARKETING_VERSIONS}" | sed '/^$/d' | wc -l | tr -d ' ')"
CURRENT_PROJECT_VERSION_COUNT="$(printf '%s\n' "${CURRENT_PROJECT_VERSIONS}" | sed '/^$/d' | wc -l | tr -d ' ')"

if [ "${MARKETING_VERSION_COUNT}" -ne 1 ]; then
  echo "Expected exactly one MARKETING_VERSION across build configurations, found:"
  printf '%s\n' "${MARKETING_VERSIONS}"
  exit 1
fi

if [ "${CURRENT_PROJECT_VERSION_COUNT}" -ne 1 ]; then
  echo "Expected exactly one CURRENT_PROJECT_VERSION across build configurations, found:"
  printf '%s\n' "${CURRENT_PROJECT_VERSIONS}"
  exit 1
fi

MARKETING_VERSION="$(printf '%s\n' "${MARKETING_VERSIONS}" | head -n 1)"
CURRENT_PROJECT_VERSION="$(printf '%s\n' "${CURRENT_PROJECT_VERSIONS}" | head -n 1)"
EXPECTED_TAG="v${MARKETING_VERSION}"

if [ "${TAG}" != "${EXPECTED_TAG}" ]; then
  echo "Release tag '${TAG}' does not match MARKETING_VERSION '${MARKETING_VERSION}'."
  echo "Expected tag: ${EXPECTED_TAG}"
  exit 1
fi

echo "Publishing ${TAG} from Xcode version ${MARKETING_VERSION} (build ${CURRENT_PROJECT_VERSION})"

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated. Run: gh auth login"
  exit 1
fi

if ! git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  echo "Tag '${TAG}' does not exist on origin. Create and push the tag before publishing."
  exit 1
fi

ZIP_PATH="dist/JustNow-${TAG}-macos.zip"
DMG_PATH="dist/JustNow-${TAG}-macos.dmg"

if [ "${SKIP_BUILD}" != "true" ]; then
  BUILD_CMD=(
    ./Scripts/local-release-build.sh "${TAG}"
    --distribution
    --notarize
    --identity "${SIGNING_IDENTITY}"
    --team "${DEVELOPMENT_TEAM}"
    --api-key "${API_KEY_PATH}"
    --api-key-id "${API_KEY_ID}"
  )

  if [ -n "${API_ISSUER_ID}" ]; then
    BUILD_CMD+=(--api-issuer "${API_ISSUER_ID}")
  fi

  "${BUILD_CMD[@]}"
fi

for artifact in "${ZIP_PATH}" "${DMG_PATH}"; do
  if [ ! -f "${artifact}" ]; then
    echo "Missing artifact: ${artifact}"
    exit 1
  fi
done

RELEASE_EXISTS="false"
if gh release view "${TAG}" >/dev/null 2>&1; then
  RELEASE_EXISTS="true"
fi

if [ "${RELEASE_EXISTS}" = "true" ]; then
  gh release upload "${TAG}" "${ZIP_PATH}" "${DMG_PATH}" --clobber
else
  CREATE_CMD=(gh release create "${TAG}" "${ZIP_PATH}" "${DMG_PATH}" --title "${TITLE}")

  if [ -n "${NOTES_FILE}" ]; then
    CREATE_CMD+=(--notes-file "${NOTES_FILE}")
  else
    CREATE_CMD+=(--generate-notes)
  fi

  if [ "${DRAFT}" = "true" ]; then
    CREATE_CMD+=(--draft)
  fi

  if [ "${PRERELEASE}" = "true" ]; then
    CREATE_CMD+=(--prerelease)
  fi

  "${CREATE_CMD[@]}"
fi

RELEASE_JSON="$(gh release view "${TAG}" --json url,body,publishedAt,isDraft,isPrerelease)"
RELEASE_URL="$(printf '%s' "${RELEASE_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')"
RELEASE_BODY="$(printf '%s' "${RELEASE_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"] or "", end="")')"
RELEASE_PUBLISHED_AT="$(printf '%s' "${RELEASE_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["publishedAt"] or "", end="")')"
RELEASE_IS_DRAFT="$(printf '%s' "${RELEASE_JSON}" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin)["isDraft"] else "false")')"
RELEASE_IS_PRERELEASE="$(printf '%s' "${RELEASE_JSON}" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin)["isPrerelease"] else "false")')"

if [ "${RELEASE_IS_DRAFT}" = "true" ] || [ "${RELEASE_IS_PRERELEASE}" = "true" ]; then
  echo "Skipping site metadata and Sparkle appcast updates for draft/prerelease ${TAG}."
else
  RELEASE_NOTES_INPUT="${NOTES_FILE}"
  TEMP_NOTES_FILE=""

  if [ -z "${RELEASE_NOTES_INPUT}" ]; then
    TEMP_NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/justnow-release-notes.XXXXXX")"
    printf '%s\n' "${RELEASE_BODY}" > "${TEMP_NOTES_FILE}"
    RELEASE_NOTES_INPUT="${TEMP_NOTES_FILE}"
  fi

  if [ -s "${RELEASE_NOTES_INPUT}" ]; then
    PUBLISHED_DATE="$(
      printf '%s' "${RELEASE_PUBLISHED_AT}" | python3 -c '
import datetime
import sys

value = sys.stdin.read().strip()
if value.endswith("Z"):
    value = value[:-1] + "+00:00"
if value:
    print(datetime.datetime.fromisoformat(value).date().isoformat())
' || true
    )"

    if [ -z "${PUBLISHED_DATE}" ]; then
      PUBLISHED_DATE="$(date -u +%F)"
    fi

  python3 "${SCRIPT_DIR}/update-site-release.py" \
    --tag "${TAG}" \
    --version "${MARKETING_VERSION}" \
      --published-at "${PUBLISHED_DATE}" \
      --notes-file "${RELEASE_NOTES_INPUT}"

    python3 "${SCRIPT_DIR}/generate-site-content.py"

    if ! "${SCRIPT_DIR}/generate-sparkle-appcast.sh" "${TAG}"; then
      echo "Warning: Failed to regenerate site/appcast.xml for ${TAG}" >&2
    fi
  else
    echo "Skipping site metadata and Sparkle appcast updates because release notes are empty."
  fi

  if [ -n "${TEMP_NOTES_FILE}" ] && [ -e "${TEMP_NOTES_FILE}" ]; then
    trash "${TEMP_NOTES_FILE}" >/dev/null 2>&1 || true
  fi
fi

printf '{"url":"%s"}\n' "${RELEASE_URL}"
