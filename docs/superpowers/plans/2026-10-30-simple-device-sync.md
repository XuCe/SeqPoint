# 简化双向同步 Implementation Plan

> 执行方式：superpowers:executing-plans；遵守用户单线程约束，由主代理实现，子代理只读探索/最终审阅。

**Goal:** PC 出码手机扫码、手机出地址 PC 连接确认后自动双向同步；同空间设备通过真实 Syncthing 跨网同步。
**Architecture:** 复用现有配对握手、LAN 拉取和自动调度。Syncthing 仅搬运单独目录中的加密发布文件，继续通过现有接收器合并。
**Tech Stack:** Flutter/Dart 3.47.2 SDK、现有 SecretStore/SQLite；官方 Syncthing v2.1.7、Go 移动桥、系统原生通道。
**Spec:** docs/superpowers/specs/2026-10-30-simple-device-sync-design.md

## 全局约束
- 单个修改步骤≤50行，只有一个[~]；步骤及验证结果记录 .codex/TODO.md。
- 先写有意义的失败测试，再实现；每个文件修改后做格式/语法校验，再推进后续步骤。
- 当前提交 fd0e6d8；不重写v0.1.0，不自动发布或合并到main，不触碰原工作区用户数据。
- 先同LAN配对；不实现首次远程配对、不合并不同既有Vault、不承诺手机后台常驻。
- 真实引擎、协议和四端构建通过才报告支持；禁止空实现、无条件短码确认或跳过证书验证冒充可用。

## 审阅重点
- 扫码票据泄漏/重放、手输地址中间人攻击、未确认时访问数据必须被阻止。
- 任一侧取消、保存失败、销毁或网络挂起，监听/轮询必须结束且不得显示成功。
- 双方原有数据保留；不同Vault拒绝；一端修改必须实际到达另一端。
- Syncthing文件乱序、冲突副本、符号链接和未到齐检查点不能污染数据或提前删除历史。
- NAS配置写入只影响本应用；错误Key、不可达数据端口及原生引擎退出必须清楚反映状态。

## Task 1: 局域网配对地址与邀请
Files: 新建 app/lib/sync/lan_pairing_link.dart、test/lan_pairing_link_test.dart（app均指apps/seqpoint_app）。
Interfaces: LanPairingAddress.parse(String)、LanPairingLink.encode/decode；携带IP列表、端口及既有PairingInvitation载荷。
- [x] 测试合法IPv4/IPv6地址、端口边界、错误协议/超大载荷、邀请过期与字段篡改；格式校验后运行观察失败。
- [x] 实现严格解析与格式化；只接受本应用二维码格式，不执行任意URL；邀请签名仍由核心协议验证。
- [x] 验证：flutter test test/lan_pairing_link_test.dart --reporter expanded，预期全通过；提交。

## Task 2: 网络配对协调
Files: app/lib/sync/app_sync_service.dart、app_sync_service_lan_pairing.dart、lan_pairing_network.dart；test/lan_pairing_service_test.dart。
Interfaces: service.lanPairing；LanPairingCoordinator.listen/connect/allow/reject/close，暴露状态、短码、二维码和本机地址。
- [ ] 使用两个真实AppSyncService和回环TLS写测试：PC出码、手机出地址两种方向、首次空间自动建立、本地数据保留。
- [ ] 独立限时配对端点自动交换已有邀请/应答/确认/授权；复用同一TLS身份，不改变现有数据端点鉴权。
- [ ] 二维码票据短时单次且绑定TLS；地址模式必须手机用户核对PC显示短码后允许，确认包绑定完整会话。
- [ ] 选择已有Vault持有者为逻辑授权方；不同Vault提前拒绝；双方安全保存并回执后才成功。
- [ ] 测试取消、超时、重复票据、错误指纹、短码不匹配、保存失败、并发请求和关闭；禁止日志输出票据/私钥。
- [ ] 验证：flutter test test/lan_pairing_service_test.dart test/sync_pairing_code_test.dart --reporter expanded；提交。

## Task 3: 局域网双向自动同步
Files: app_sync_service.dart、app_sync_service_automatic.dart、新建app_sync_service_lan.dart；test/automatic_lan_sync_test.dart。
Interfaces: setLanEnabled(bool)、rememberLanPeer({deviceId,host,port})；沿用syncOnce和AutoSyncScheduler。
- [ ] 测试两端连接后A创建→B收到、B修改→A收到；持久化对端地址；重启/断网重连、暂停和撤销。
- [ ] 配对完成后双方启动数据监听并经认证交换端口；仅绑定已授权设备，地址不接受任意转发目标。
- [ ] 自动调度覆盖LAN与既有relay，单个失败不能阻止其他目标；生命周期结束取消任务，保留现有云同步行为。
- [ ] 验证：flutter test test/automatic_lan_sync_test.dart test/automatic_sync_service_test.dart --reporter expanded；提交。

## Task 4: 配对界面与扫码
Files: app/lib/settings/sync_settings_page.dart、app/lib/sync/lan_pairing_page.dart、lan_qr_scan_page.dart、app/pubspec.yaml、移动平台权限文件；test/lan_pairing_page_test.dart。
- [ ] 用既有设置组件测试PC等待二维码、手机扫一扫、手机等待地址、PC输入、手机允许、失败/取消和重新连接。
- [ ] 接入最小二维码/扫码依赖及相机权限；二维码不保存到公共文件/日志，切换后台关闭相机。
- [ ] 主流程隐藏原始邀请文本和Vault管理；高级入口保留旧配对、恢复和HTTPS节点。
- [ ] 验证：flutter test test/lan_pairing_page_test.dart test/basic_entries_test.dart --reporter expanded；flutter analyze；提交。

## Task 5: 真实四端Syncthing宿主
Files: native/syncthing/go.mod、mobile/engine.go、mobile/engine_test.go、构建脚本；app/lib/platform/syncthing_engine_host.dart及Android/iOS原生通道。
Interfaces: Go Start(home,guiAddress,apiKey string) error / Stop() error；Dart实现既有SyncEngineHost。
- [ ] 固定官方v2.1.7提交d6d0181f7d466381c4b39ec8fd944c364f939b32；记录MPL-2.0许可证和第三方notice。
- [ ] 测试启动、loopback REST身份、重复启动、失败清理、停止和持久身份；Go错误附上下文，服务/context具明确退出。
- [ ] 移动桥启用仅loopback的REST和独立API Key，禁用自更新；保留数据库/证书，API调用不阻塞Flutter UI。
- [ ] 桌面使用固定版本官方二进制及已核验哈希，受控进程；停止等待monitor及子进程退出，不仅kill外层。
- [ ] 验证go test ./mobile与go vet ./...；gomobile生成AAR/XCFramework；先完成真实小文件双向传输再接应用目录。

## Task 6: 加密发布目录传输
Files: core/lib/src/sync/transport/folder_transport.dart、lan_sync_runtime.dart、sync_content_transfer.dart、sync_checkpoints.dart；对应核心测试（core指packages/seqpoint_core）。
Interfaces: FolderTransport沿用VaultTransport；LanSyncRuntime.syncFolder(FolderTransport)；发布读取helper显式接收providerDeviceId。
- [ ] 测试路径边界、大小限制、符号链接、临时/冲突文件和写者限制；实现现有FolderTransport空方法，复用SyncFiles。
- [ ] 导出publishedFiles白名单到独立目录，封口日志、逐文件原子写入，禁止一次加载所有附件或复制整个sync-vault。
- [ ] 复用控制链、检查点、日志和附件接收逻辑；删除LanTransport强转仅限读取发布视图分支，Relay专属逻辑保持。
- [ ] 测试真实目录A→B→A、重复/乱序/缺块重试、撤销/epoch边界；未到齐检查点不得导致旧数据提前清除。
- [ ] 验证dart test test/sync/folder_sync_test.dart与受影响的LAN/checkpoint/content测试；提交。

## Task 7: Syncthing管理与应用装配
Files: app/lib/sync/syncthing_client.dart、app_sync_service_syncthing.dart、app/lib/main.dart、app/lib/app/seq_app.dart；test/syncthing_client_test.dart、syncthing_service_test.dart。
Interfaces: SyncthingClient以EngineEndpoint配置本机与管理端；AppSyncService可选SyncEngineHost；仅主窗口持有引擎。
- [ ] 测试管理地址、证书、错误Key及API响应；Key仅入SecretStore、不进偏好/日志/二维码。
- [ ] 自动取得NAS Device ID、登记本机真实ID、创建当前Vault专用Folder并配置双方共享，保留无关设置，重复执行幂等。
- [ ] 同一Vault配对是前置条件；文件夹到达后调用syncFolder合并，不把REST配置完成当作同步完成。
- [ ] 注入 main→SeqApp→AppSyncService；不依赖未被调用的PlatformRegistry，不在便签子窗口重复启动。
- [ ] 用真实Syncthing实例验证跨进程文件传输、双向应用合并、暂停/重连、无关目录保留与Key撤销；提交。

## Task 8: 交付验证
Files: 同步设置、引擎构建/打包脚本、现有CI及部署说明；对应UI与端到端测试。
- [ ] 接通管理地址＋一次Key输入、明确连接/传输/合并状态；iOS前后台限制不伪装成持续后台同步。
- [ ] 在四端构建中生成/带入所需引擎、相机权限和许可文件；保留已有Linux构建，不新增自动发布步骤。
- [ ] 跑受影响测试、静态分析和Android/iOS/macOS/Windows构建；区分自动验证与未完成的真机验证。
- [ ] 独立审阅整个改动及上方五类风险；修复重要问题并验证，记录提交、测试和剩余限制。
- [ ] 当前任务不打新tag、不发Shorebird补丁；完整新版获发布授权后才能交付给已安装v0.1.0用户。
