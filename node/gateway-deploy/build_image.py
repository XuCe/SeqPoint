#!/usr/bin/env python3
"""不依赖 Docker 生成网关镜像 tar（docker save 格式，可在群晖「从文件添加」或 docker load 导入）。

镜像内容与 package.sh 中 Dockerfile 一致：FROM scratch，只有网关二进制、
属主 65532 的 /data 数据目录和 /ipdb 离线 IP 地区库，以非 root 用户运行。

用法：build_image.py <二进制> <ipdb目录> <架构 amd64|arm64> <输出tar> [标签]
"""
import hashlib
import io
import json
import os
import sys
import tarfile

# 固定时间戳让同样输入得到同样的镜像。
EPOCH = 1700000000
CREATED = "2023-11-14T22:13:20Z"
UID = 65532


def entry(name, kind, mode, uid=0, size=0):
    info = tarfile.TarInfo(name)
    info.type = kind
    info.mode = mode
    info.uid = info.gid = uid
    info.uname = info.gname = ""
    info.mtime = EPOCH
    info.size = size
    return info


def layer(binary, ipdb):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as tar:
        with open(binary, "rb") as f:
            data = f.read()
        tar.addfile(entry("seqpoint-node", tarfile.REGTYPE, 0o755, size=len(data)), io.BytesIO(data))
        tar.addfile(entry("data", tarfile.DIRTYPE, 0o755, uid=UID))
        tar.addfile(entry("ipdb", tarfile.DIRTYPE, 0o755))
        for name in sorted(os.listdir(ipdb)):
            if not name.endswith(".xdb"):
                continue
            with open(os.path.join(ipdb, name), "rb") as f:
                data = f.read()
            tar.addfile(entry("ipdb/" + name, tarfile.REGTYPE, 0o644, size=len(data)), io.BytesIO(data))
    return buffer.getvalue()


def main():
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    binary, ipdb, arch, out = sys.argv[1:5]
    tag = sys.argv[5] if len(sys.argv) == 6 else "seqpoint-gateway:1"
    if arch not in ("amd64", "arm64"):
        sys.exit("arch must be amd64 or arm64")
    rootfs = layer(binary, ipdb)
    diff_id = "sha256:" + hashlib.sha256(rootfs).hexdigest()
    config = {
        "architecture": arch,
        "os": "linux",
        "created": CREATED,
        "config": {
            "User": f"{UID}:{UID}",
            "ExposedPorts": {"8080/tcp": {}, "8081/tcp": {}},
            "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
            "Entrypoint": ["/seqpoint-node"],
            "Cmd": ["-gateway"],
        },
        "rootfs": {"type": "layers", "diff_ids": [diff_id]},
        "history": [{"created": CREATED, "created_by": "seqpoint gateway-deploy/build_image.py"}],
    }
    if arch == "arm64":
        config["variant"] = "v8"
    config_bytes = json.dumps(config, separators=(",", ":"), sort_keys=True).encode()
    config_id = hashlib.sha256(config_bytes).hexdigest()
    layer_dir = diff_id.split(":", 1)[1]
    name, version = tag.rsplit(":", 1)
    manifest = [{"Config": config_id + ".json", "RepoTags": [tag], "Layers": [layer_dir + "/layer.tar"]}]
    files = {
        config_id + ".json": config_bytes,
        layer_dir + "/VERSION": b"1.0",
        layer_dir + "/json": json.dumps({"id": layer_dir, "created": CREATED, "os": "linux",
                                         "architecture": arch}).encode(),
        layer_dir + "/layer.tar": rootfs,
        "manifest.json": json.dumps(manifest).encode(),
        "repositories": json.dumps({name: {version: layer_dir}}).encode(),
    }
    with tarfile.open(out, mode="w", format=tarfile.PAX_FORMAT) as tar:
        tar.addfile(entry(layer_dir, tarfile.DIRTYPE, 0o755))
        for path, data in files.items():
            tar.addfile(entry(path, tarfile.REGTYPE, 0o644, size=len(data)), io.BytesIO(data))
    print(f"{out}: {tag} linux/{arch} layer {diff_id[:19]}")


if __name__ == "__main__":
    main()
