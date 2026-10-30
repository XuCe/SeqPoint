#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export GOTOOLCHAIN="$(sed -n 's/^toolchain //p' go.mod)"
: "${GOTOOLCHAIN:?Missing pinned Go toolchain}"
mkdir -p artifacts
if [[ "${1:-}" == android || "${1:-}" == ios ]]; then
  mkdir -p artifacts/tools
  go build -o artifacts/tools/gobind golang.org/x/mobile/cmd/gobind
  export PATH="$PWD/artifacts/tools:$PATH"
fi
version_flags='-X github.com/syncthing/syncthing/lib/build.Version=v2.1.7'
case "${1:?Specify android, ios, macos, windows or linux}" in
  android)
    go tool gomobile init
    # anet's Android interface compatibility requires this on Go >= 1.23.
    go tool gomobile bind -target android/arm64,android/arm -androidapi=26 \
      -tags noassets -ldflags "$version_flags -checklinkname=0" -javapkg com.seqpoint.syncthing \
      -o artifacts/seqpoint-syncthing.aar ./mobile
    ;;
  ios)
    go tool gomobile init
    go tool gomobile bind -target ios,iossimulator -iosversion=15.0 \
      -tags noassets -ldflags "$version_flags" \
      -o artifacts/SeqpointSyncthing.xcframework ./mobile
    ;;
  macos|linux)
    if [[ "$1" == macos ]]; then
      export MACOSX_DEPLOYMENT_TARGET=12.0
      export CGO_CFLAGS="${CGO_CFLAGS:--O2 -g} -mmacosx-version-min=12.0"
      export CGO_LDFLAGS="${CGO_LDFLAGS:--O2 -g} -mmacosx-version-min=12.0"
    fi
    go build -tags noassets -ldflags "$version_flags" -o artifacts/syncthing \
      github.com/syncthing/syncthing/cmd/syncthing
    ;;
  windows)
    go build -tags noassets -ldflags "$version_flags -H windowsgui" -o artifacts/syncthing.exe \
      github.com/syncthing/syncthing/cmd/syncthing
    ;;
  *) printf '%s\n' 'Unsupported platform' >&2; exit 2 ;;
esac
