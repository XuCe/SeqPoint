#!/usr/bin/env bash
set -euo pipefail

# native_adaptive_toolbox 0.1.0 exports an underscored library, while Flutter
# requests a hyphenated SwiftPM product. Keep the Swift module name unchanged.
dart pub cache add native_adaptive_toolbox --version 0.1.0
plugin_dir="${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev/native_adaptive_toolbox-0.1.0"
for platform in ios macos; do
  manifest="$plugin_dir/$platform/native_adaptive_toolbox/Package.swift"
  sed -i.bak 's/\.library(name: "native_adaptive_toolbox"/.library(name: "native-adaptive-toolbox"/' "$manifest"
  grep -Fq '.library(name: "native-adaptive-toolbox", targets: ["native_adaptive_toolbox"])' "$manifest"
  rm -f "$manifest.bak"
done
