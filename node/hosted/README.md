# 运营一个序点托管节点

每个邀请开通一个资料库。运营方持有本机 Syncthing 管理凭据，用户只收到七天有效的一次性 HTTPS 链接。同一设备中断后可以重试。资料库共享加密内容，运营方可看到文件大小、目录名和设备标识。

## 部署

1. 在 Linux 主机上为此功能运行一个专用 Syncthing 实例。管理端监听 HTTP `127.0.0.1:8384`，开启管理登录，保存 API key。保留设备发现或中继，按需开放同步端口 22000。关闭默认共享目录。授权服务与 Syncthing 共用本机网络和同一套目录路径。
2. 在已启用 qgroup 配额的 Btrfs 文件系统上准备 `HOSTED_DATA`，将目录属主设为 Syncthing 运行用户。准备单独的 `HOSTED_STATE` 目录，属主设为授权服务用户，权限 0700。两个进程都须能遍历到数据目录。在挂载点运行 `btrfs quota enable <挂载点>` 并等待初次配额扫描结束。
3. 用 Go 1.25 或更高版本在仓库的 `node` 目录运行 `go build -o seqpoint-hosted ./hosted`。为进程设置以下环境并由服务管理器运行一个 `seqpoint-hosted` 实例。通过权限 0600 的服务环境文件注入 `STGUIAPIKEY`。节点身份与配置、注册表、邀请目录、配额数据需一起持久化和备份。

```sh
HOSTED_ORIGIN=https://sync.example.com
HOSTED_STATE=/var/lib/seqpoint-hosted
HOSTED_DATA=/srv/seqpoint-vaults
```

4. 将真实域名指向服务器。Caddy 可用以下配置终止 HTTPS。公网只需访问邀请页与授权接口，8384 和 8385 都仅在本机监听。

```caddyfile
sync.example.com {
    @hosted path /invite /v1/enroll
    reverse_proxy @hosted 127.0.0.1:8385
    root * /srv/seqpoint-links
    file_server
}
```

5. 用可创建 Btrfs 子卷和设置配额的账号执行以下命令。脚本先设置硬配额，再生成邀请。将最后一行完整链接私下交给用户。默认每个资料库 1 GiB，可用 `HOSTED_QUOTA=2G` 等覆盖。限制作用于该资料库的同步文件，Syncthing 的索引和日志需要额外磁盘空间。

```sh
sudo env HOSTED_ORIGIN=https://sync.example.com HOSTED_STATE=/var/lib/seqpoint-hosted \
  HOSTED_DATA=/srv/seqpoint-vaults bash hosted/invite.sh
```

服务端拒绝匿名登记和跨库委托。管理员可以在兑换前删除对应的邀请文件以取消邀请。已配对设备用签名批准新设备，撤销成员后，下次托管同步会提交撤销名单并移出节点共享目录。离线期间的撤销在恢复连接后生效。

## 手机点击邀请直接打开 App

将以下域名替换为运营域名。无域名关联的构建以及桌面端可以在设置中粘贴同一个完整链接。

- **Android** 构建时同时传入环境变量 `HOSTED_HOST=sync.example.com` 和 Flutter 参数 `--dart-define=HOSTED_ORIGIN=https://sync.example.com`。在域名的 `/.well-known/assetlinks.json` 发布 `delegate_permission/common.handle_all_urls` 声明，目标为 Android 包 `com.seqpoint.app` 和实际发布签名的 SHA-256 指纹。
- **iOS** 为 App ID 和签名描述文件开启 Associated Domains，在 `ios/Flutter/Hosted.local.xcconfig` 写入 `SEQPOINT_ENTITLEMENTS = Runner/Hosted.entitlements` 和 `HOSTED_HOST = sync.example.com` 两行，并传入同一 Flutter 参数。域名的 `/.well-known/apple-app-site-association` 应授权实际 Team ID 与 `com.seqpoint.seqpointApp` 的 `/invite` 路径。两份关联文件须支持直接 HTTPS GET，使用 JSON 内容类型。Caddy 可为无后缀的 Apple 文件设置 `header /.well-known/apple-app-site-association Content-Type application/json`。

发布前用真实签名的手机安装包点击邀请。首台设备确认节点域名后开通，第二台与其配对并确认短码，随后断开局域网同步，分别编辑一条笔记确认双向收取。在 Linux 测试节点写满一个小配额子卷，确认出现配额错误且其他资料库仍可写。
