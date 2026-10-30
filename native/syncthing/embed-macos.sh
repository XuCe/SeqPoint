#!/usr/bin/env bash
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
helper="$native_dir/artifacts/syncthing"
if [[ ! -x "$helper" ]]; then
  echo 'error: Build Syncthing first: bash native/syncthing/build-engine.sh macos' >&2
  exit 1
fi
destination="${TARGET_BUILD_DIR:?}/${EXECUTABLE_FOLDER_PATH:?}/syncthing"
install -m 755 "$helper" "$destination"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --entitlements "$native_dir/helper.entitlements" "$destination"
