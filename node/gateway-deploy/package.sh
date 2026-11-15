#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?pass an absolute destination directory}
[[ "$out" == /* ]] || { echo 'destination must be absolute' >&2; exit 2; }
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/data" "$work/ipdb"
# 离线 IP 地区库（ip2region，Apache-2.0）。网关本地查询，不调用外部服务。
# 可用 IPDB_DIR 指向已下载好的 ip2region_v4.xdb / ip2region_v6.xdb，避免重复下载。
for name in ip2region_v4.xdb ip2region_v6.xdb; do
  if [[ -n "${IPDB_DIR:-}" && -f "$IPDB_DIR/$name" ]]; then
    cp "$IPDB_DIR/$name" "$work/ipdb/$name"
  else
    curl -fL --retry 5 -C - -o "$work/ipdb/$name" \
      "https://raw.githubusercontent.com/lionsoul2014/ip2region/master/data/$name"
  fi
done
cat > "$work/Dockerfile" <<'DOCKER'
FROM scratch
COPY seqpoint-node /seqpoint-node
COPY --chown=65532:65532 data /data
COPY ipdb /ipdb
USER 65532:65532
EXPOSE 8080 8081
ENTRYPOINT ["/seqpoint-node"]
CMD ["-gateway"]
DOCKER
# Docker 守护进程不可用（未安装、未启动或无权限）时，用 build_image.py 直接拼出同样内容的镜像 tar。
if docker info >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then builder=docker; else builder=python; fi
for arch in amd64 arm64; do
  GOOS=linux GOARCH=$arch CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$work/seqpoint-node" .
  if [[ $builder == docker ]]; then
    docker buildx build --platform "linux/$arch" -t seqpoint-gateway:1 \
      --output "type=docker,dest=$out/seqpoint-gateway-$arch.tar" "$work"
  else
    python3 gateway-deploy/build_image.py "$work/seqpoint-node" "$work/ipdb" "$arch" \
      "$out/seqpoint-gateway-$arch.tar"
  fi
done
cp gateway-deploy/{compose.yaml,README.md} "$out/"
