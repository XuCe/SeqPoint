# SeqPoint 个人云中转节点

Go 标准库文件节点 + Caddy HTTPS，支持手机和电脑跨网络、错时交换数据。
A 上传后可以离线，B 稍后打开应用同步即可收到；B 修改并上传后，A 下次同步收到。
不需要 MySQL、Redis、Syncthing 或客户端公网 IP。

## 当前范围与限制

- 每个实例服务一个 Vault。设备先在应用内配对，再由管理员配置设备公钥白名单。
- 便签、事项、标签及删除/恢复使用端到端加密同步；可显式开启图片附件和录音原文件同步，含已有文件。
- 文字与可压缩分块先 gzip、再加密；至少节省 5% 才使用压缩，PNG/JPEG/M4A 等通常保持原编码，接收后原文件逐字节一致。
- 正文及附件内容加密；Vault/设备 ID、密文文件名、大小、成员公钥及签名控制记录等元数据可见。
- 配置云地址后默认自动同步：本地编辑约 2 秒去抖（连续编辑最多等 10 秒），空闲约 60 秒检查一次。
  桌面应用运行时持续工作；手机前台运行或回到前台时补传，系统挂起/杀死应用期间不保证同步。主动暂停会保留。
- 移动网络也同步原文件：1 MiB 明文分块，平均约 2 MiB/s 节流，每轮媒体 8 MiB、检查点 16 MiB 预算；
  成功分块持久缓存，断线/重启后只补缺块。网络错误从 5 秒退避至最多 5 分钟并带抖动；有进展的待传队列约 2 秒续传，无进展回到常规检查间隔。
- 未变化媒体批量检查清单，每小时完整复核分块；已有正确密文不重复上传。
- **历史不再因累计 64 MiB / 1000 段而停止同步**：云端发布带原作者证明的加密检查点后回收覆盖的封口日志；
  LAN 在 100 段 / 16 MiB 前后转为检查点传输。离线设备可从检查点恢复，并继续接收新编辑。
- 节点及客户端按小时清理过期检查点密文与不再引用的块，至少保留 24 小时在途宽限；当前检查点和可恢复的媒体保留。
  这不是无限容量：节点默认总配额 1 GiB，单个密文文件 12 MiB，图片原文件 20 MiB、录音 50 MiB；仍需为有效数据和在途检查点预留磁盘。
- 不依据未签名 ACK 删除历史。回收前校验完整检查点、原作者证明和块哈希；同步不能替代独立备份。
- 请求必须有白名单设备签名，时间差须在 60 秒以内。请保持服务器和客户端自动校时。
  重放缓存有界且在内存中，进程重启会清空；HTTPS 和客户端签名日志验证仍然必需。

## 1. 准备手机和电脑

两端安装包含本次云中转功能的应用版本。在“设置 → 同步”准备本机身份，
由一端创建同步空间，按现有配对流程完成邀请、响应及双方短码确认。
不要在两端分别创建不同空间。只有已经配对的设备才能解密彼此的数据。

配对完成后，在创建空间的一端点击“云中转 → 复制节点配置”。
复制的是当前空间及已授权设备的公钥，不包含设备私钥或解密密钥。
保存完整 JSON 为服务器 `node/node.json`。`node.example.json` 只是格式示例，不能直接运行。

## 2. 准备服务器

将本仓库整个 `node/` 目录（包括 Go 源码）上传到服务器，例如 `/opt/seqpoint/node`。
服务器需已安装 Docker Engine 与 Docker Compose 插件。
将域名（例如 `sync.example.com`）的 A/AAAA 记录指向服务器，开放 TCP 80、443；UDP 443 可选。
如设置 AAAA，IPv6 也必须可达。不要公开节点内部的 8080 端口。

```sh
cd /opt/seqpoint/node
cp .env.example .env
# 编辑 .env：SEQPOINT_DOMAIN=你的域名（不要加 https:// 或路径）
# 将应用复制的完整 JSON 保存为当前目录的 node.json
chmod 644 node.json
# 配置仅含公钥；容器以非 root 用户运行，需要能够读取此文件
docker compose config --quiet
docker compose up -d --build
docker compose ps
docker compose logs --tail=40 node caddy
```

Caddy 会申请、续期 HTTPS 证书；`node_data` 保存加密历史，`caddy_data` 保存证书。
这些都是持久卷，重建容器不会清空。**不要运行 `docker compose down -v`**，它会删除这些卷。
配置依据：[Docker Compose 生产部署](https://docs.docker.com/compose/how-tos/production/)、
[Caddy 自动 HTTPS 的域名、端口与持久存储要求](https://caddyserver.com/docs/automatic-https)。

## 3. 验证并连接客户端

```sh
curl https://你的域名/
# 应返回 SeqPoint relay is running（只证明 HTTPS 入口正常）
curl -o /dev/null -s -w '%{http_code}\n' https://你的域名/seqpoint/relay/v2/scan
# 未签名请求应返回 401，证明节点拒绝匿名读取
```

两台设备都填同一个 `https://你的域名`，不要加 API 路径，点击“保存地址”。
保持“自动云同步”开启；需要原文件时，两端都打开“同步附件和录音”（包含已有附件，移动网络也会传输）。
第一次可按这个顺序验收：

1. A 新建测试便签，点击“云同步一次”，确认本轮完成后退出 A。
2. B 换到另一网络后打开应用，点击“云同步一次”，确认收到该便签。
3. B 修改便签再同步、退出 B；A 之后同步，确认收到修改。
4. 添加图片/录音，等待待传提示消失；在 B 验证图片可预览、录音可播放。
5. 暂停/恢复网络、重启服务器后重复一次，确认补传及历史仍可接收。

只显示“已完成本轮云端交换”不能证明对端收到，仍需在对端检查。
同步失败可以重试，只补传缺失或变更内容，重复接收不会重复生成记录。

## 4. 更新、增删设备与备份

从旧版升级：先完成两端安全备份与节点卷备份，再升级所有客户端和节点/Caddy。
新节点可读取旧数据；首次检查点回收前会持久写入 V2 标记，此后 V1 请求返回 426。
**不要在回收后降级客户端或节点，也不要删除协议标记来绕过检查**，旧客户端不能从检查点追赶。
准备撤销设备时，先让保留设备接收其完整数据和原文件。
撤销后已在可信设备接收的检查点可重新加密发布，原文件可由持有者接管；
未曾接收、无法证明撤销前边界的旧历史不会被强行信任。

新增设备：先完成应用内配对，再从有最新成员记录的设备重新复制节点配置。
撤销设备：在应用内撤销后，重新导出节点配置以同时撤销节点访问权限。
仅修改服务器白名单不等同于应用内密钥轮换。其他设备下一次同步才会收到成员变更。
将新配置替换为 `node.json`，然后重新创建节点容器，使文件绑定与配置都重新加载：

```sh
docker compose up -d --force-recreate node
# 升级时同时重建入口，加载新增的 V2 路由：
docker compose up -d --build --force-recreate node caddy
```

备份前停止节点写入，使用同一 Compose 项目运行：

```sh
mkdir -p backups
docker compose stop node
docker run --rm --volumes-from "$(docker compose ps -aq node)" \
  -v "$PWD/backups:/backup" alpine:3 \
  tar czf /backup/node-data.tgz -C /data .
cp node.json .env backups/
docker compose start node
```

也应备份 Caddy 的证书卷以及两端应用各自的安全备份。**只有服务器密文不能恢复解密密钥**。
还原服务器时，在停机状态下将归档解包到新的空 `node_data` 卷，保留归档中的 UID/GID（65532），
并还原原来的 `node.json` 和 `.env`；不要换 Vault ID 后继续混用旧数据。
不要直接删除旧日志来腾空间，离线设备可能永远无法补齐历史。

## 排错

| 现象 | 处理 |
|---|---|
| TLS/证书错误 | 检查 DNS、80/443、防火墙和 Caddy 日志；客户端要求系统信任的证书 |
| HTTP 401 | 检查同一 Vault、设备公钥配置、双方系统时间；大量请求后等待一分钟再试 |
| HTTP 403 | 只能写入当前签名设备名下的文件，检查设备身份与配对状态 |
| HTTP 413 | 检查单文件/总配额及磁盘；在 node.json 调整 quotaBytes 后重建 node，预留检查点空间，不能盲删历史 |
| HTTP 426 | 空间已启用 V2 回收，升级所有客户端；不要降级或删协议标记 |
| HTTP 409 | 检查点并发更新或版本冲突；自动同步会先拉取新版本再重试 |
| HTTP 500/503 | 检查数据卷权限、剩余空间和节点日志，稍后重试 |
| 旧客户端仍报 64 MiB / 1000 段 | 安装 V2 客户端，先让有完整本地历史的设备同步生成检查点 |
| 等待密钥或前序日志 | 让有最新成员记录/未上传历史的设备先同步，再重试；不要跳过缺失段 |
| 刚复制配置仍401 | 确认文件来自最新配对状态，并已重新创建节点容器加载新配置 |

节点配置只在启动时读取。运行账号需能读配置并写数据目录。
节点按请求触发小时级密文回收；长期无请求不会定时唤醒。可恢复媒体不会因删除标记而立即清除。
异常掉电后可检查 `.tmp-*` 残留，先备份再人工处理；不可手工删除当前检查点或其引用块。
正常进程重启、网络中断及重复请求已测试；无法以单次测试保证云厂商磁盘或备份永不损坏。

## 本地开发验证

需要 Go 1.25+ 与仓库现用 Dart/Flutter。仅测试可通过 CLI 指定自签 TLS 证书；
生产使用 Compose 的 Caddy，客户端不绕过系统证书校验。

```sh
# 从仓库根目录运行
(cd node && go test -race ./... && go vet ./... && go build -o /tmp/seqpoint-node .)
(cd packages/seqpoint_core && SEQPOINT_NODE_BINARY=/tmp/seqpoint-node \
  dart test test/sync/relay_node_integration_test.dart test/sync/relay_media_test.dart \
  test/sync/relay_resume_test.dart test/sync/relay_large_history_test.dart \
  test/sync/relay_lan_checkpoint_test.dart test/sync/relay_epoch_checkpoint_test.dart)
(cd apps/seqpoint_app && flutter test --no-pub test/relay_settings_test.dart test/app_sync_service_test.dart)
```

集成测试实际启动 Go HTTPS 节点和两个本地数据库，覆盖 A 离线、节点重启、B 稍后接收并回传、
A 再接收、重复去重、分块续传/损坏修复、原文件一致、撤销后历史保留，
及超过 64 MiB / 1000 段后的压缩回收和继续同步。未代表已在你的域名或移动真机上验收。
