#!/usr/bin/env bash
# 扫描仓库中的密钥模式；命中则退出 1。对应 NFR-113「密钥零泄露」。
#
# 扫描范围只含代码与配置：docs/ 下的设计文档会包含用于演示的示例密钥串，
# 故整体排除；真正要防的是密钥进入源码、构建产物、日志与导出文件。
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERN='sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|sb_api_[A-Za-z0-9]{40,}|gh[pousr]_[A-Za-z0-9]{36,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA|EC|OPENSSH|PRIVATE) '

if grep -rIlE \
    --exclude-dir={.git,.codex,build,.dart_tool,ephemeral,Pods,vendor,docs,node_modules,target,dist,.next} \
    --exclude='go.sum' --exclude='*-lock.json' --exclude='pnpm-lock.yaml' \
    --exclude='*.lock' --exclude='*.md' --exclude='scan_secrets.sh' \
    "$PATTERN" . | grep -vFx './packages/seqpoint_core/test/sync/transport/fixtures/localhost_key.pem'; then
  # 唯一豁免是 CI 自动生成的回环 TLS 测试私钥；只输出命中文件名。
  echo "✗ 发现疑似密钥，禁止提交" >&2
  exit 1
fi
echo "✓ 未发现密钥模式"
