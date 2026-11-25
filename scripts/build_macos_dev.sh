#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_DEFINES="${CLIENT_DIR}/dart_defines.dev.local.json"

cd "${CLIENT_DIR}"

if [[ $# -eq 0 ]]; then
  ARGS=(build macos --debug)
else
  ARGS=("$@")
fi

if [[ -f "${LOCAL_DEFINES}" ]]; then
  exec flutter "${ARGS[@]}" --dart-define-from-file="${LOCAL_DEFINES}"
else
  exec flutter "${ARGS[@]}"
fi
