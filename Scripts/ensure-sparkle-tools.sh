#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/sparkle-config.sh"

ARCHIVE_PATH="${SPARKLE_TOOLS_CACHE_DIR}/${SPARKLE_TOOLS_ARCHIVE}"
EXTRACT_DIR="${SPARKLE_TOOLS_CACHE_DIR}/extracted"

if [ ! -x "${EXTRACT_DIR}/bin/generate_appcast" ] || [ ! -x "${EXTRACT_DIR}/bin/generate_keys" ]; then
  mkdir -p "${SPARKLE_TOOLS_CACHE_DIR}"

  if [ ! -f "${ARCHIVE_PATH}" ]; then
    gh release download "${SPARKLE_VERSION}" \
      --repo "${SPARKLE_TOOLS_REPO}" \
      -p "${SPARKLE_TOOLS_ARCHIVE}" \
      -D "${SPARKLE_TOOLS_CACHE_DIR}" >/dev/null
  fi

  if [ -d "${EXTRACT_DIR}" ]; then
    trash "${EXTRACT_DIR}"
  fi
  mkdir -p "${EXTRACT_DIR}"
  tar -xf "${ARCHIVE_PATH}" -C "${EXTRACT_DIR}"
fi

printf '%s\n' "${EXTRACT_DIR}"
