#!/usr/bin/env bash
# 回环传输测试专用；随机生成，不提交证书或私钥。
set -euo pipefail
cd "$(dirname "$0")/.."
fixture=packages/seqpoint_core/test/sync/transport/fixtures
if [ -s "$fixture/localhost_key.pem" ] && [ -s "$fixture/localhost_cert.pem" ]; then
  exit 0
fi
umask 077
mkdir -p "$fixture"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj '/CN=seqpoint-transport-test-only' \
  -addext 'subjectAltName=IP:127.0.0.1,IP:::1' \
  -keyout "$fixture/localhost_key.pem" \
  -out "$fixture/localhost_cert.pem" >/dev/null 2>&1
echo '✓ 回环 TLS 测试证书已准备'
