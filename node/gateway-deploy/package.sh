#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?pass an absolute destination directory}
[[ "$out" == /* ]] || { echo 'destination must be absolute' >&2; exit 2; }
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/data"
cat > "$work/Dockerfile" <<'DOCKER'
FROM scratch
COPY seqpoint-node /seqpoint-node
COPY --chown=65532:65532 data /data
USER 65532:65532
EXPOSE 8080 8081
ENTRYPOINT ["/seqpoint-node"]
CMD ["-gateway"]
DOCKER
for arch in amd64 arm64; do
  GOOS=linux GOARCH=$arch CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$work/seqpoint-node" .
  docker buildx build --platform "linux/$arch" -t seqpoint-gateway:1 \
    --output "type=docker,dest=$out/seqpoint-gateway-$arch.tar" "$work"
done
cp gateway-deploy/{compose.yaml,README.md} "$out/"
