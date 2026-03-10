#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: ./Scripts/generate-sparkle-appcast.sh <tag>" >&2
  exit 1
fi

TAG="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/sparkle-config.sh"

TOOLS_DIR="$("${SCRIPT_DIR}/ensure-sparkle-tools.sh")"
ARCHIVE_PATH="dist/JustNow-${TAG}-macos.zip"

if [ ! -f "${ARCHIVE_PATH}" ]; then
  echo "Archive not found: ${ARCHIVE_PATH}" >&2
  exit 1
fi

python3 "${SCRIPT_DIR}/generate-sparkle-appcast.py" \
  --tag "${TAG}" \
  --archive "${ARCHIVE_PATH}" \
  --generate-appcast-bin "${TOOLS_DIR}/bin/generate_appcast" \
  --key-account "${SPARKLE_KEY_ACCOUNT}" \
  --download-url-prefix "${SPARKLE_RELEASE_DOWNLOAD_BASE_URL}/${TAG}/" \
  --site-url "${SPARKLE_SITE_URL}" \
  --release-notes-url "${SPARKLE_RELEASES_URL}"
