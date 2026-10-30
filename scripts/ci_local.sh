#!/usr/bin/env bash
# 本地 CI：与 GitHub Actions 跑同一套检查。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── 密钥扫描 ──"
scripts/scan_secrets.sh
bash scripts/prepare_test_tls.sh

echo "── 依赖解析 ──"
dart pub get > /dev/null

echo "── 核心层 ──"
(cd packages/seqpoint_core && dart analyze && dart test)

echo "── 应用层 ──"
(cd apps/seqpoint_app && flutter analyze && flutter test)

echo "✓ 全部通过"
