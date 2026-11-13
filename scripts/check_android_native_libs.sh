#!/usr/bin/env bash
# 校验 APK 带齐了运行时 dlopen 的原生库；缺一个就会启动即失败
# （例如缺 libsqlite3.so 时报 "Failed to load dynamic library ... not found"）。
#
#   scripts/check_android_native_libs.sh path/to/app.apk
set -euo pipefail

apk=${1:?用法：$0 path/to/app.apk}
listing=$(unzip -Z1 "$apk")
missing=0
for abi in arm64-v8a armeabi-v7a; do
  for lib in libsqlite3.so; do
    if ! grep -qx "lib/$abi/$lib" <<<"$listing"; then
      echo "✗ $apk 缺少 lib/$abi/$lib" >&2
      missing=1
    fi
  done
done
[ "$missing" -eq 0 ] || exit 1
echo "✓ $apk 已包含 libsqlite3.so（arm64-v8a、armeabi-v7a）"
