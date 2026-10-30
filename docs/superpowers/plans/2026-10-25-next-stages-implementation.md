# 后续阶段 Implementation Plan

> **For agentic workers:** 用户2026-10-26授权分模块子代理并行实现；使用 subagent-driven-development/dispatching-parallel-agents，主会话按文件归属整合、审查及回归，`.codex/TODO.md`锚定唯一进行中批次。

**Goal:** 完成已批准的六阶段交付，保留真实的平台与配置验收边界。
**Architecture:** 复用 Flutter 应用、纯 Dart 核心及现有平台接口；主引擎持有调度和生命周期。恢复先保护旧库，再替换并重建容器；同步沿用单写者加密文件方案。
**Tech Stack:** Flutter/Dart、SQLite、现有 cryptography/http 与平台插件；已有能力优先，不为少量逻辑引入依赖。
**Spec:** `docs/superpowers/specs/2026-10-25-next-stages-design.md`（用户已批准推荐分期并授权自动执行）。

## 排期表

以下是从 2026-10-25 起的预估执行窗口（America/Los_Angeles），不是定时等待或完成承诺；能提前完成就继续下一项。外部条件不齐时完成可验证部分并记录，继续无依赖工作。

| 阶段 | 预估窗口 | 交付 | 依赖 / 退出条件 | 当前进度 |
| --- | --- | --- | --- | --- |
| 1 桌面收尾 | 10-25 | 可用 macOS 场景验收、复现问题修复、Windows 清单 | 真机缺失项保留未验收，不阻断核心开发 | 10 项测试通过；CUA/Windows 原生项未验收 |
| 2 提醒闭环 | 10-26—10-28 | 期限计划、持久化对账、撤销、启动恢复与点击定位 | 核心/通道/界面测试通过；原生精度另验 | 已实现；core 241/app 143 通过；macOS/iOS 模拟器构建通过；真机待验 |
| 3 备份恢复 | 10-29—10-31 | 未加密本机快照、JSON/Markdown 导出、安全恢复入口 | 故障注入验证旧数据安全，明示内容范围 | 本地可验证交付完成；core307/app199通过，Root17/设置26项；macOS/iOS模拟器构建通过，真机保存待验 |
| 4 AI 整理 | 11-01—11-03 | 单次请求、结果预览、选择采纳、幂等 | 复用提供方配置；无密钥时用确定性测试，不发送用户记录 | 本地交付完成；真实Mac Data Protection Keychain当前解锁会话隔离读写通过；真实模型及锁屏/重启/iOS/Android安全存储仍待验 |
| 5 双机同步 | 11-04—11-10 | 身份/配对/局域网加密文件交换与合并 | 双实例验证重传、离线冲突、删除；真机网络另验 | 已于10-26完成首批App主服务/手动配对/恢复新身份/控制冲突/设备撤销；临时双/三实例真实TLS及独立审查通过，真实局域网/后台/密钥仍待设备 |
| 6 移动多媒体 | 11-11—11-17 | 图片、语音输入、录音和纪要逐项闭环 | 权限、附件、取消/失败测试；设备/转写配置不足如实记录 | 首批图片/短句语音/录音播放导出/导入转写确认与AI纪要入口已交付并独立审查；实际音频/识别/保存待真机，自动长转写未实现且不列本批退出项 |
| 总验收 | 各阶段后及全部完成时 | 测试、静态分析、适用平台构建、独立只读审查 | 不能把模拟测试当真机通过，不能把缺配置模块标为完成 | 本机首批完成：core884/App413、严格分析、Mac/iOSsim debug通过；P3跟踪外部条件，无变化静默 |

## Global Constraints

- 保留本轮开始前的全部未提交改动；在 `codex/next-stages` 分支原地执行，不搬走尚未提交的桌面实现。
- 用户2026-10-26授权分模块子代理并行实现、主会话本地集成；TODO保留一个总批次`[~]`，代理按独占文件并行，内部每次修改≤50行并单文件校验；主会话独占共享入口/文档，交付先审查再回归。
- 测试先 RED 再 GREEN；错误连续修复两次仍失败就熔断，保留现场并报告，不能第三次盲改。
- 超过 200 行先 rg 定位，仅读目标附近；跨 4 个以上未知文件的探索派只读子 Agent。
- 不读取依赖/产物目录和锁文件；测试/构建日志用静默模式或 tail 截至 40 行，并保留真实退出码。
- 允许主会话本地整合代理代码；不自动合并远端、推送、发布，不对用户真实记录执行恢复，不把测试数据混入正式数据。
- 用户批准未加密本机快照；JSON/Markdown 仅明文导出。加密可携带备份和 Recovery Key 后置。

## Review Focus

- 通知安排与持久化之间崩溃：同一稳定 ID 可重试，旧计划最终可取消，不能丢失所有权。
- 超过 500 个事项、父便签删除、连续改期：不能遗漏计划或让已取消计划复活。
- 恢复中途崩溃、损坏/未来版本、重开失败：旧库与保护快照始终可用。
- AI 重复点击/部分采纳、超时/坏响应：不重复创建，不丢原文，不泄露密钥。
- 同步重复/乱序/冲突与附件取消/权限拒绝：数据可收敛，失败不生成假成功记录。

## 顺序任务与验收

### 1. 桌面验收
- [x] 运行现有桌面常驻/后台快捷键/托盘通道测试，10 项通过，未复现新问题。
- [x] 检查原生 UI 验收条件：CUA 无法访问后台无窗口应用，launch_app API 不可用；操作本身未验收。
- [x] 记录 macOS/Windows 未验项目，继续无依赖的提醒开发。
文件：既有 `apps/seqpoint_app/lib/desktop/panel/main_panel.dart`、`platform/desktop_tray.dart`、桌面生命周期测试；仅复现问题才编辑。
验证：`flutter test --no-pub test/desktop_residency_test.dart test/desktop_background_hotkeys_test.dart test/desktop_tray_channel_test.dart --reporter compact`，退出 0。

### 2. 提醒计划与平台接线
- [x] 核心持久化稳定通知计划，未来触发计算及连续改期/相对/去重/超 500 条查询测试通过。
- [x] 串行协调器取消旧计划、安排新计划、稳定 ID 重试、漏期汇总及系统队列丢失后的启动重建已验证。
- [x] 主引擎初始化通知；SeqApp 复用 Bootstrap.db 创建协调器，AppScope 传递状态；子窗不调度，主引擎每 5 秒读共享库。
- [x] 完成/删除撤销、整签恢复仅恢复未来计划、暂停/恢复/销毁、前台对账均有回归验证。
- [x] 冷启动与运行期点击查当前数据、定位事项并返回原签，失效提示与草稿保护已验证。
- [x] 权限拒绝/初始化失败/重试状态可见；iOS 最早 64 条窗口、超额 pending 提示与补位已验证。
- [ ] 真机原生通知触发/精度、权限变化、设备重启及 Windows 同 ID 队列数量仍需实测。
文件：`packages/seqpoint_core/lib/src/reminder/`、`repo/reminder_repository.dart`、数据库迁移及相邻测试；应用 `app/`、`main.dart`、通知平台实现和生命周期测试。
接口：核心只返回持久化计划，不依赖 Flutter；应用用 NotificationService.schedule/cancel/responses 对账，新增字段/签名进入阶段时逐项固化。
验证：核心提醒定向测试、相关 app 测试、逐文件 analyze；阶段结束运行应用/核心测试集，退出 0。

### 3. 本机备份与安全恢复
接口固化：`SnapshotService.validate(File snapshot) -> int` 同步只读预检，返回已支持 schema；必要结构按项目迁移构造参考库核对，原快照不迁移。
恢复协议使用同目录候选、保护副本和持久化标记；下次启动打开正式库前回滚未完成替换。只承诺进程中断恢复，不宣称断电持久性。
会话接口位于 `backup/restore_session.dart`：`RestoreSession.prepare(File snapshot, {required String targetPath}) -> Future<RestoreSession>`；调用前关闭全部目标库连接，保留当前文件，生成保护副本与已迁移候选；源文件不修改。
`apply()` 先核对无目标辅助文件，再写入并 flush 固定标记后替换；`commit()` 在调用方重开及代表性查询成功后才清除标记；`rollback()` 与静态 `recover(String targetPath)` 从保留的保护副本回滚，失败保留标记并阻止正常启动。
事务内核验候选必须使用 `Bootstrap.run(dbPath: ..., recoverPendingRestore: false)`，关闭失败的新连接后才回滚；默认启动仍先 recover。构造失败自动关闭DB。
当前格式不允许额外触发器/视图；prepare 清理无标记的工作文件前先清理全部辅助文件，并拒绝源与任一工作主/辅助文件同实体。真实子进程遗留WAL回归已覆盖独立审查所提缺陷。
标记不存外部路径，工作文件均从目标路径派生；未开始替换时目标字节不变。恢复前另留可见手动快照，内部工作副本在无标记的下一次准备中清理，提交后不冒险删除唯一旧副本。
Ruling：既有子窗没有保存/关闭握手，首批恢复遇到任何子窗即拒绝并提示手动保存关闭，不自动丢弃草稿。恢复暂停通知并撤销原库计划，失败则重新安排旧库提醒。
文件选择器已接file_picker11.0.3；桌面选目录，移动端使用系统单文件保存，恢复读取所选文件缓存副本。
- [x] SnapshotService 只读完整性/外键/表列结构/版本检查；坏文件/未来版本/额外执行型schema拒绝，v1–v5兼容，源字节不变。
- [x] 核心会话覆盖复制/替换/重开失败、空标记、进程中断、保护副本损坏和真实遗留WAL；28项会话测试通过。
- [x] 内部保护副本、同盘候选、替换标记、提交/回滚及启动恢复接线完成；独立审查1项问题已修复，全量core280/app146通过。
- [x] 核心唯一手动快照已实现，失败不覆盖旧件，每日轮转不删除手动件；恢复前另留可见手动保护快照。
- [x] 应用恢复暂停调度及读写、拒绝任何子窗/编辑器/退出中的恢复、关闭 DB、替换并重建 Bootstrap/AppScope；失败恢复旧容器。现有子窗无安全关闭握手，不自动丢弃输入。
- [x] JSON关联筛选、独立事项、Markdown完整性与同步事务收集完成；同盘暂存后唯一发布，半写失败保留旧件。独立审查2项P2已修复，core297/app146通过。
- [x] 桌面设置页实际选择目录导出JSON/Markdown，忙/失败/取消提示及5项交互测试通过；应用全151项与分析通过，macOS debug构建通过。
- [x] 移动端原生单文件保存JSON/Markdown ZIP，内存构建且iOS唯一副本finally清理；15项跨平台设置交互/通道测试及全app161/core298通过，真机保存待验。
- [x] 立即备份/快照列表接入support/snapshots并明示未加密；重复有效副本、目录失败重试、写失败保留旧件、忙保护均验证，设置共19项GREEN，移除虚假每日快照与Recovery Key占位。
- [x] 文件/列表选择→只读预检→确认→Root切库接线；Root17项/设置26项通过，取消不写库、错误可重试、忙状态防重复。
- [x] 最终core307/app199及三包分析通过；macOS debug/iOS simulator debug构建成功，git diff --check通过。独立审查1项P2已复现修复，补唯一约束/FK/必填额外列预检。
- [ ] iOS/Android真实文件提供方保存与恢复选择、Windows原生行为仍待设备验证；未对用户真实数据恢复。
恢复接线核对已完成：主引擎仅一份Bootstrap连接，额外连接来自子便签引擎。正常设置路径无隐藏编辑器，仍在任何pop前保守拒绝已挂载的NoteEditor/QuickCapturePage/ItemEditorPage与全部非当前窗口。
恢复期间保留主壳/托盘/热键实例，AppScope传递忙状态，面板阻止后台入口与DB计数查询；先暂停开窗、等待在途原生create完成（错误/超时中止）再枚举，避免仅缓存判空及创建竞态。
原子顺序：窗口屏障TDD→忙状态/面板屏障→Bootstrap当前所有权/提醒回调屏障→Root保护/撤销/关闭/会话替换/候选核验/commit或回滚→文件/列表确认UI→整体验证。每块继续≤50行，容器/数据库切换时不重建整个MaterialApp，避免旧壳异步解绑破坏新热键。
文件：`backup/snapshot_service.dart`、`export/exporters.dart`、`app/bootstrap.dart`、`app/seq_app.dart`、`settings/backup_settings_page.dart` 及对应测试。
验证：核心故障注入与往返测试、设置交互/取消/失败测试，逐文件 analyze；不对正式库执行恢复演练。
实现记录：file_picker13/12与已有win32约束冲突，官方metadata确认11.0.3兼容并已解析通过；macOS两份用户选择读写entitlement均plutil通过。移动目录不作Dart可写路径使用，JSON/Markdown ZIP交原生保存，取消清理iOS应用副本；Android系统提供方结果不能当POSIX路径验证，UI不宣称外部保存原子性或云端持久化。
来源：[file_picker11.0.3](https://pub.dev/packages/file_picker/versions/11.0.3)、[Apple目录授权](https://developer.apple.com/documentation/uikit/providing-access-to-directories)、[Android文档存储](https://developer.android.com/training/data-storage/shared/documents-files)、[archive](https://pub.dev/packages/archive)。

### 4. AI整理接口固化（只读探索后决定）
当前provider/service/applier及确认卡均为空，设置未持久化；不把静态条目当已配置能力。首批只接移动便签详情和桌面便签窗的已保存便签手动入口。
Ruling：单一OpenAI兼容Chat Completions提供方；用户配置baseURL/model（无硬编码模型），云端默认关闭。配置存shared_preferences，key仅经现有SecretStore/SecureSecretStore使用，不进SQLite/导出/日志；不新增依赖或表。
发送前确认目标提供方与当前已保存原文，既有标签仅本地匹配；不读取全局选中内容、附件、其他便签或系统凭据。HTTP单次调用，超时/拒绝/坏JSON明确报错，不自动重试或静默回退。
官方接口核对：[Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)。兼容接口采用JSON模式加明确JSON提示，本地严格核对字段；JSON模式本身不保证schema。
文件与契约：
- core `ai/openai_compatible_provider.dart` 实现既有AiProvider.complete/ping，使用http.Client工厂注入，调用结束关闭客户端；ProviderConfig.baseUrl/model/timeout在网络前验证。错误不带key、原文或原始响应；禁自动重定向。
- `ai/organize_proposal.dart`增加sourceContent与稳定候选ID，copyWith保留身份；`organize_service.dart`消费配置与调用时key，产出proposal，不落库。
- `ai/organize_applier.dart`注入现有数据库/仓储；apply仅处理accepted，事务内复查原文及行号占用，候选ID作为Item主键以保证重复采纳幂等；标签/活动同事务。正文变化或删除拒绝陈旧提案，空选择不写。
- app配置模块注入preferences/SecretStore；`settings/ai_settings_page.dart`保存/清除配置、脱敏显示，禁把“已配置”写成“已连接”。
- `shared/organize_confirm_card.dart`预览逐项选择、标题/期限/重要程度/标签与采纳/取消；不声称recurrence/reminderHint/noteTitle已落库。
- `mobile/note_detail_page.dart`及`desktop/sticky/sticky_window.dart`只接当前保存便签；异步返回核对mounted、恢复状态与DB身份，再预览/采纳/刷新。
原子步骤（每次修改≤50行，单文件校验；测试RED→最小实现→GREEN后再下一块）：
- [x] HTTP MockClient22项通过：请求去向/授权/JSON、超时、坏配置、禁重定向、HTTP/坏响应/截断/拒绝及64KiB原文/256KiB响应流边界；无真实请求。
- [x] 提案身份2项及service28项通过：严格字段/行号/时区日期、已有行/项目新词过滤、原文/key隔离，本地明确规则，无错误静默回退。
- [x] applier21项通过：部分/重复/陈旧/冲突/非法候选、四处写失败回滚及两个WAL连接重叠事务。空undo占位移除，首批不声称撤销可用。
- [x] 配置仓储14项通过：默认本地、配置单JSON、按地址隔离密钥、读/写/清除错误脱敏、损坏配置；正式入口open先reload避免多引擎缓存。普通配置不承诺断电落盘；[插件官方说明](https://pub.dev/packages/shared_preferences)。
- [x] 配置仓储14项+真实设置9项通过：持久化/按地址隔离key、保存/清除/失败重试与云端告知；不读取旧明文key、不宣称已连接。
- [x] 确认卡7项/按钮20项通过；两端真实保存便签入口已贯通预览、选择采纳与刷新，保留原文；取消、失败、重复、原文变化/换库/卸载各await屏障已验证。
- [x] core380/app249、两层分析通过，AI独立只读审查无确认P0/P1/P2；iOS simulator/Android debug构建成功，git diff --check通过。
- [x] Mac开发签名已通过：用户明确批准三配置切K29Y36X47U；本Mac登记/profile配置后xcodebuild退出0，Flutter标准macOS debug构建成功。iOS当前已有K29值由原有变更保留，本补丁只改Mac。
- [ ] 真实模型/API计费与设备网络、iOS/Android安全存储和Mac锁屏/重启仍待验。Mac真实SecureSecretStore/Data Protection已在当前解锁会话以UUID隔离读写并清理通过；未读取生产API key/用户DB，生产main产物已恢复。
原生检查：已按[Flutter网络要求](https://docs.flutter.dev/cookbook/networking/fetch-data)补mac沙盒客户端与Android main联网；按[安全存储10.3.1说明](https://pub.dev/packages/flutter_secure_storage/versions/10.3.1#macos--ios)补Keychain空groups、iOS三配置引用与Android禁系统自动备份，CF/XML均通过。
历史签名排查（现已由上方K29构建结果更新）：Mac原ad-hoc不能使用Keychain。初用既有FQ3证书/团队且用户授权profile获取后，Xcode仍报No Accounts/缺profile，按规则停止盲试。用户确认后只读核对新增证书，发现团队K29并获单独授权切换，随后登记本Mac完成开发配置；未读取私钥或上传应用。
Android首次编译的file_picker11/AGP9 Kotlin缺口已按[维护者认可的项目级修复](https://github.com/vicajilau/flutter_file_picker/issues/2200)处理，仅给该插件补KGP/JVM17；局部Kotlin/app javac及完整APK均通过。保留版本与Flutter迁移开关，不动注册类/缓存，不做全局Kotlin迁移。

### 5. 双机同步接口与顺序
首批范围：便签、事项、标签和关联；不传AI密钥、活动、通知计划或平台设置。沿用根目录同步V1，SQLite本体不共享。
Ruling：未实现“全部有效成员ACK且有覆盖快照”之前，完全保留段文件，TTL不能替代ACK/快照；现有明文codec只供测试，不能据此显示同步已开启。
Ruling：复用cryptography的XChaCha20-Poly1305/Ed25519/X25519/HKDF；私钥、Epoch密钥和恢复种子只进系统SecretStore，普通配置只含公开身份和连接信息。
Ruling：先手动填写局域网HTTPS地址并核对配对短码；mDNS、云中转及Syncthing适配后续，不阻塞首批。移动端不能依赖系统openssl命令生成证书。
Ruling：对象按(type,id)隔离；普通字段更新不能复活墓碑，必须有明确恢复操作。导入必须在业务投影/去重/水位提交后才发ACK。
Ruling：便签子引擎只写共享DB的事务outbox，主引擎唯一发布文件；文件先同盘暂存再原子发布。发布前持久保存封装字节，崩溃重试复用同一段/操作ID。
Ruling：恢复先暂停并排空同步；恢复旧业务库不得倒退发布序号或复用旧设备身份。初版恢复后解除同步，重新配对前禁止发布，相关UI必须明示。
原子任务按下列顺序展开；每个测试/实现编辑≤50行，当前文件校验后才换文件，RED→GREEN后才进入下一项：
- [x] S5.1 4个新断言真实RED后关闭自动回收/TTL捷径，VaultStore.reclaim安全返回0；逐文件分析及31项同步测试GREEN。
- [x] S5.2 XChaCha20帧/AAD/错误key/截断/篡改/随机nonce4项与Ed25519互操作/错误公钥/修改消息/不可变密钥3项RED→GREEN；已有cryptography2.9.0，无新依赖，导出与逐文件分析通过。
- [x] S5.3 DeviceKeys3项与SyncIdentityStore6项通过：完整SHA256公钥指纹、X25519协商、系统安全存储单记录/回读确认、重开/并发稳定、损坏和部分写失败拒绝；只用假存储，未验收真实Keychain。
- [x] S5.4 加密codec6项/文件原子与路径6项/加密Store集成1项GREEN：规范头+密文+Vault/用途认证，验签后解密，拒绝未知成员/Epoch/坏操作，8MiB正文/12MiB文件上限；明文默认移除。同盘flush+rename，半写保留旧段，拒绝路径错配/符号链接。
命名对齐V1的YYYYMM-NNNN；序号全局递增，跨月先原子发布已认证sealed标记，再新段。接收方未见封口不得跳月，避免新月先到时漏旧月尾部。仅测试夹具迁移，没有已有生产vault或用户数据迁移。
本检查点core403/app255及两层分析通过；核心须用dart test（Flutter运行器不支持既有恢复子进程用例的Isolate.resolvePackageUri），未修改恢复实现。尚无持久DB导入/真实配对，不能显示安全同步已开启。
- [x] S5.5 A–G已完成：v6、SAVEPOINT、持久HLC/差异、notes/items/tags/关联/AI及级联、恢复断开，core458/app256与分析GREEN。备份保留禁trigger/view，v1–v6支持；没有真实配对或持久导入验收。
- [x] S5.6 持久HLC、去重与LWW投影、完整段收据/封口水位同事务及提交后ACK；故障回滚/原子ACK重试、双独立DB加密且均重开收敛通过。core591/app257及两层分析GREEN，真实App同步仍关闭。
- [x] S5.7 初始存量基线、事务prepared原bytes发布、故障重试/序号恢复与停止排空完成；真实加密磁盘双库收敛/封口后ACK/重开通过，core661/app257及两层分析GREEN，App真实同步未启用。
- [x] S5.8 本机配对/成员协议与假安全存储完成：双端材料/随机数/期限/TLS绑定、双方确认与checkpoint AAD、签名父权限/撤销轮换/分叉暂停及重开；真实配对UI与存储验收仍S5.10/11。
- [x] S5.9 HTTPS模块/自有可信目录/pinned证书/同步当前鉴权及有界超时路径完成；loopback/重定向/陌生撤销/竞态通过，TLS自生成和PKCS12真握手通过；实际App组合与真机留S5.10/11。
- [x] S5.10 首批App主引擎/手动配对/状态/恢复互斥与提醒role、新身份/控制冲突恢复、PRD P0设备撤销产品接线完成，不显示虚构进度；真机与后置通道另列。
- [x] S5.11 本机临时双/三实例TLS、离线修改/重开/撤销、新身份/控制冲突与独立复核通过；完整core884/App413、两层严格分析、Mac/iOSsim编译通过。真机网络/后台/系统密钥仍未验。
S5.5只读核对后的事务契约：
- 选显式仓储捕获与可嵌套SAVEPOINT；不引入触发器，保留快照拒绝任意trigger/view的防注入边界。所有公开业务写入口可穷举，不做全表前后扫描。
- 捕获notes/items/tags字段实际差异及item_tags集合差异；业务原SQL与操作记录同一SAVEPOINT。AI直接关联INSERT、purge及tags merge/delete的级联需显式覆盖。
- v6新增sync_local（公开writer/开关/持久HLC/恢复后须换身份）、sync_operations（不可变opId/来源/发布段）、sync_publications（待发布密文字节/文件名/状态）。复用sync_state作接收水位，不另建重复字段缓存。
- 操作表无指向业务对象的级联外键，物理删除仍保留墓碑；唯一opId及(writer,millis,counter)防重复。按对象字段/HLC、待发布操作建索引。
- 默认同步关闭且无writer，普通业务不积累伪造设备操作；启用时主引擎原子建立存量基线。各DB连接每次捕获读取同一公开状态，密钥不进SQLite。
- 导入抑制只作用于当前连接，并用try/finally恢复；不切全局开关，不吞掉并行子引擎写入。时间在线上传UTC，投影恢复本地数据库既有时间格式。
- 同名标签唯一约束必须在S5.6投影中解决（内置标签当前随机ID）；不能直接插入两端不同ID的同名标签后宣称收敛。
S5.5原子队列（各项继续按≤50行拆编辑、单文件校验）：
- [x] A v6三表/索引与约束完成；迁移/去重/默认关闭3项GREEN，现有DB/备份86项全通过（含旧快照/恢复），私钥不进表。
- [x] B 四项嵌套事务真实RED→GREEN；独立命名SAVEPOINT保持同步返回值，外层回滚覆盖已释放内层，内层失败不误伤外层，已有调用方事务不被提交。core411全通过，单文件分析通过。
- [x] C SyncOutbox8项GREEN/分析通过：事务字段差异、两个连接/回拨/重开HLC、失败/外层回滚、连接级嵌套导入抑制、明确恢复与墓碑；默认关闭不读快照或发操作。尚未接仓储，不宣称业务已自动产生outbox。
字段边界：窗体window_json、旧整行hlc与设备来源source_ref_json留本机；便签/事项业务时间以UTC上线，保留原始业务字段与显式恢复意图。
- [x] D notes/items insert/update完成；便签/事项各5项真实入口与故障用例GREEN，事项连同既有service/applier45项通过。删除/恢复意图区分，冲突拒绝不产操作；尚不覆盖物理purge/关联，留E/F。
D1便签insert/update5项+18项既有NoteService测试GREEN；D2事项insert/update5项GREEN，含行转事项、勾选、合并编辑、冲突拒绝及直接仓储/外层活动失败回滚。
- [x] E 关联差集/AI写入已接；E2标签初始化/upsert/rename5项GREEN，与既有标签及AI同步共10项通过。重复保持身份不发操作，唯一冲突/操作失败/内置批次中途失败回滚业务及HLC。
E1完成：关联差集3项/AI采纳同步2项GREEN，连同原applier共25项通过。未变关联不DELETE，重复添加无操作；撤旧/新增后操作失败整批回滚，AI绕仓储INSERT已改addTag，关联ID无分隔符歧义。E2标签写入待接。
- [x] F 标签级联与事项/便签purge完整捕获；F2期限/重复/三层墓碑失败回滚重试4项+旧服务22项GREEN。最终core449/app255及两层分析通过；旧恢复启动故障夹具已适配跳过重复builtin插入，仍真实验证失败回滚。
F1标签合并/删除5项GREEN，与旧标签用例8项通过：源关联/标签墓碑完整，目标已有关联不重建，内置删除保护与自身合并无操作，失败全回滚。嵌套捕获暴露旧HLC快照复用，新增固定时钟真实RED→修复追加前读取最新状态；基础9项GREEN。
- [x] G 核心9项与真实Bootstrap新集成1项GREEN，恢复候选清公开同步状态、关闭并要求新身份；v5源/保护副本/回滚/启动恢复正确，低阶入口也同盘候选清理。备份88项、app恢复47项及最终core458/app256/分析通过；确认界面已明示重新配对。
G只读核对决定：在RestoreSession候选迁移后、apply前调用共享断开方法，清devices/sync_state/operations/publications并重建关闭的sync_local、requires_new_identity=1；不动源/保护副本/系统私钥。低阶SnapshotService.restore也先同盘候选迁移/断开/校验再替换，避免绕过；rollback/recover继续原样复制保护副本，普通启动不清绑定。
之后进入S5.6的持久导入/去重/水位与发布状态机，不能用当前内存SyncEngine代替持久验收。
S5.6接收契约与原子队列：
- 持久事实只用sync_operations，不另建可丢失的合并缓存。先验签解密完整段，再在单事务严验/去重/观察HLC/业务投影/水位；提交后才写文件ACK，失败可重试。
- opId重传须内容完全一致；同writer同HLC不同操作整批拒绝。未知字段、本机字段、非法类型/时区/关联键均拒绝，不静默丢弃。
- 对象命名空间为(type,id)，可见性仅看最新明确restore与tombstone；普通字段再新也不复活。缺父对象/创建必填字段则持久保留操作并延迟投影，后续批次须重新处理依赖。
- [x] A SyncObjectKey为(type,id)记录，FieldMerge/losers/SyncEngine及测试已迁移；命名空间RED及旧墓碑复活/标记泄漏真实RED→GREEN，8项合并/85项同步测试通过，逐文件分析通过。
- [x] B Operation共享字段/ID契约和严格入站4项GREEN（含真实仓储全字段加密往返）；日期规范为UTC DateTime.toIso8601String，拒绝溢出/本机字段/坏关联。SyncInbox9项GREEN：精确重传、伪重复/同HLC冲突、错误脱敏、整批/外层回滚、重开与下一本地时钟；只存事实，不投影/写水位/ACK。最终core474/app256及两层分析通过。
- [x] C 便签/事项投影16项GREEN：SQL字段LWW及作者决胜、完整事实不足等待、父后到/临时库重开、墓碑/明确恢复、索引/FK与本机窗口/来源/旧hlc保留、跨对象故障整批回滚。core506/app257及两层分析全GREEN；无生产接收/水位/ACK启用。
- C1一致性边界：已有业务行与空库均须完整创建事实，不以业务列补齐赢家；delete-only/restore-only同样持久等待。S5.7必须在首次真实导入前建立本地基线；当前操作保存成功不代表所有业务已收敛。
C0已完成：真实复现SQLite最大counter自增回绕为负数；Hlc统一tick支持进位，Outbox复用，绝对耗尽明确失败。SyncInbox最多接受比本机超前5分钟的HLC（历史离线操作保留），越界整批拒绝/不推进水位，不改已有opId时间。26项时钟/收发基础与完整core479/两层分析GREEN；app测试上次256，本轮未重复。校时后旧日志仍超前时须新身份重配/基线，不静默重写旧操作。
- [x] D 固定角色归组、同名保ID、逻辑名/启动/持久投影及唯一约束下交换、占名等待/故障回滚通过；未把isIdea属性修正冒称提醒/今日已集成。
- [x] E 归一关联marker、缺依赖/未知alias/重开、跨alias删除重加、标签墓碑先事实化关系再清理及故障回滚通过。
- [x] F 全段事实/投影/收据/封口水位同事务，提交后原子ACK、失败重试不重写、DB证明拒伪水位、双库加密且均关闭重开通过；最新core591/app257与两层分析GREEN。
标签裁定已只读固化，D实施时逐项验证；不把设计裁定冒充唯一约束或想法语义已经通过。
标签只读裁定补充（D实施前按以下边界展开）：
- 内置type按现有9个固定角色索引归一为builtin-type:i；仅合法kind/builtin/sort组合入组，canonical身份元数据不可漂移。先跨原ID归组再取字段和restore/tombstone赢家，canonical仅name增量也可定位；不临时按到达顺序吞ID。
- 关联按(itemID,canonicalTagID)归组后计算标记，canonical删除须压过旧别名restore，真实新添加仍可恢复；不采用旧alias tag_id字段赢家作为实际FK。
- 普通project/custom/非内置type同名保ID，稳定排序确定赢家，其余确定性消歧，并处理与用户原名/其他后缀二次碰撞。保留唯一索引，不引入不可重建的临时别名。
- 派生显示名须保留原业务名：D拟用v8 tags.logical_name nullable本机列（不上wire），真实改名清除、显示名noop保留；Outbox/基线读逻辑名，投影写回。不能靠剥后缀猜原名。新列须补迁移和旧快照兼容验证。
- C1前置时间基础：数据库日期统一UTC固定六位小数文本，继续普通范围索引；wire操作JSON/签名字节保持原样。v7仅迁移日期列，同事务失败回滚，禁止测试真实用户库。旧无偏移日期只能沿用本机DateTime.parse解释，无法恢复历史缺失的时区/DST歧义。
- 时间基础逐文件队列：编码排序/DST测试→编码→临时库迁移测试→日期迁移函数→v7事务接入→直接SQL日期写入→本地日界→人类显示toLocal→核心/app回归；每次≤50行并单文件校验后推进。
- 时间基础验收完成：LA全量core490/app257、两层分析及UTC专项51项通过；九表迁移/坏值回滚/协议和密文不变/本地显示已验收，仅临时数据。v7为日期迁移，后续标签元数据用v8。
- ensureBuiltins按固定角色/遗留角色判断存在，改名重启不补默认名。Tag.isIdea优先角色并兼容逻辑名，project/custom同名不误判；当前无想法SQL过滤，不能将属性修正冒称系统提醒/今日过滤已接入，S5.10对账时另核对调用。
- D1纯事实归组已9项/全部同步128项GREEN：九固定角色、先跨alias归组再合并标记，普通同名保ID。显示名分配先保留角色/再按ID排序，预留全部原业务名，派生全ID后缀遇碰撞递增；不改原操作或唯一索引。
- D2本机元数据与启动部分已完成：v8 logical_name/行映射/角色想法/复制与真实改名、Outbox逻辑名及显示noop；初始化按角色和持久事实，不复活墓碑/未完增量。默认名冲突共用分配器、临时名仅在事务内存在且不进outbox。core529/app257/两层分析GREEN，仅临时数据；标签持久投影/关联/提交后ACK尚未完成。
- D持久投影10项/完整core540/app257与两层分析通过；E关联8项与全部同步156项/core分析通过，缺依赖/未知alias等待，关联事实化后才清标签墓碑，投影拒写同批全回滚。
- F生产水位裁定：sync_state.applied_seq与ACK仅表示连续完整封口前缀，开放段事实可持久接收但不推进；同seq增长须保留此前操作，封口后必须原bytes不变。v9收据保存远端段header/hash（不混本机publication），远端操作标记所属seq；恢复候选清收据。缺seq等待，不按月重置。
- F单次读取验签/解密所得Segment、ops、原bytes才可决定sealed/count，不能混扫描旧header；事实/投影/收据/水位同事务，提交后原子写ACK。ACK失败保留DB结果，重试不重复业务写；依赖待投影计数保存最近投影结果，不把已持久ACK等同业务全部收敛。
S5.7发布与基线契约：
- v10 baseline_ready区分首次完成与空库；首次从关闭/无操作发布收据历史开始，同writer重复初始化幂等。恢复须新身份标志由配对层处理，基线不能绕过；已有历史却关闭时拒绝静默重启/清空。暂停传输应继续捕获，不能把enabled关闭当暂停后直接恢复。
- 首启用在同一短事务先获取写锁、冻结所有notes/items/tags/item_tags（含归档/回收站）；仅协议字段，tag取logical_name，关联编码身份/present。完整基线/HLC/ready/enabled原子提交，初次真实导入晚于该提交；基线后先投影规范身份，不能借现有行补赢家。
- 发布单引擎串行：短事务冻结身份、publication版本与最多500个待发布op；事务外签名加密；再检查身份/版本后原子存最终bytes并仅绑定冻结opId。期间新增操作留后批；不跨await持SQLite事务，不把远端操作发布为本机。
- 有未完成prepared先补发布，复用原bytes/路径/seq；文件成功才标published，文件已写但标记失败可重试。DB有历史而文件缺失可原bytes重发；本机目录有DB不认识的文件则停止，不按文件最大seq或空目录重置。
- 开放tail固定createdAt/epoch/前缀；封口也是prepared版本。跨月/容量先封口发布旧段，再分配全局下一seq；除500条外沿用8MiB明文/12MiB文件界限，单操作超限保留待发布并明确失败，不能死循环或丢弃。
- 原子队列：基线与幂等→冻结/编码/prepared→原bytes发布重试→tail/封口/月/尺寸→重开/多连接/恢复排空。仅临时DB/目录/测试密钥，不操作真实用户数据库。
- S5.7 A/B完成：v10 ready迁移/恢复重置、Outbox完整快照复用与真实操作校验、SyncBaseline独立事务写锁/全部存量/逻辑名/归档回收站、幂等/旧历史及须新身份拒绝、拒写全回滚与双连接原子可见性通过。完整core602/app257及两层分析GREEN；冻结/prepared/原字节发布仍待C–E，不能直接用VaultStore.append代替。
- S5.7C1完成（2026-10-26）：SyncPublisher.freeze以同步短事务冻结最多500条本机操作/标量值及publication头、原bytes与状态；整行快照供C2比较版本，不新增迁移。身份/ready/恢复、异writer、连续序号/孤立绑定/头计数检查，prepared优先返回原版本；列表/字节不可变，双连接真实仓储新增与临时库重开通过。
- C1验证：14项定向、完整core616/app257及两层分析GREEN，独立复核无阻塞发现。仅临时DB与测试段；头解析不代表验签，C2事务外认证编码/CAS及D文件发布、E发布器验收仍待完成，App真实同步未启用。
- S5.7C2完成（2026-10-26）：prepare在事务外认证旧段及签名加密，同月同epoch延续原tail；跨月/epoch/容量先封口旧段，确认published后才取全局下一seq。精确UTF8 JSON装箱含数组/逗号，500条或8MiB满额立即封口，12MiB文件上限及单操作超限均不丢待发事实；未发布prepared只复用原bytes。
- C2提交以短同步事务CAS完整头/原bytes/身份/ready，逐项复核冻结事实与认证prefix，原子保存prepared并仅绑定选中opId；新增留后批，变值/删除/竞争/拒写全回滚。25项C2定向、完整core641/app257及两层分析GREEN，独立复核无阻塞发现；仅临时DB/测试密钥，D文件发布与E发布器验收仍待完成，真实App同步未启用。
- S5.7D完成（2026-10-26）：Store认证prepared原bytes及既有开放前缀，拒绝改写封口段/陌生本机文件/链接/路径错配；同盘暂存后逐字节复核，最终同步替换前再次检查文件未变。Publisher串行选择DB已有缺文件或新prepared，不从目录决定seq；短独立DB事务内复核身份/头版本/绑定事实，再rename、标published，所有await均在事务外。
- D验证：16项定向及完整core657/app257、两层分析GREEN。覆盖静默短写、加密认证失败、文件成功而确认失败、恢复断开、跨实例迟到暂存拒绝、跨月序号、旧缺文件原bytes补发、磁盘DB关闭重开原bytes补确认；只用临时目录/DB/测试密钥。E整体验收与恢复排空仍待完成，App真实同步尚未启用。
- D复核补修（2026-10-26）：修复非.log陌生普通文件/目录被跳过的历史屏障缺口，仅豁免DB已知段对应的普通UUIDv4暂存文件；伪暂存、未知段暂存和同名目录均拒绝，合法崩溃残留仍可恢复。新增3项回归，发布/恢复21项（含E排空2项）、完整core672/app257与两层分析GREEN，独立复核确认问题关闭；仅故障注入/临时数据，未做真机断电验收或启用真实App同步。
- S5.7E完成（2026-10-26）：prepare/publish共用串行actor队列，stop拒绝新请求并等待此前接受的编码/文件IO全部结束，排空后可关闭旧DB；失败仍由各调用方接收。两个磁盘临时DB经真实加密基线/发布/持久接收双向收敛，并发不同字段保留、远端不回声、开放不提前ACK、封口后ACK、两端重开无重复通过。
- S5.7最终完整core661/app257及两层分析GREEN。基线、事务prepared、原bytes发布与重试、停止/排空和持久接收的本机交付完成；实际App恢复接线、配对/成员、HTTPS与真机验收留后续S5.8–S5.11，未使用真实数据/密钥/设备或启用App同步。
S5.8执行契约（只读核对后）：
- 现有pairing/成员/Epoch存储仅接口骨架，复用已验证DeviceKeys、Ed25519、XChaCha20及cryptography内置HKDF，不新增依赖；先完成纯本机会话与假存储验收，再接HTTPS和App，不能提前显示已配对。
- 固定角色顺序的规范transcript绑定协议用途、Vault/session、双方完整签名/协商公钥身份、各自32字节随机数、UTC期限和TLS SHA256指纹；输入严格限长并复制不可变，不用目录或自报deviceId建立信任。
- QR一次性秘密与X25519共享秘密用于HKDF，会话短码与确认凭据绑定同一transcript；双方确认、未过期/取消且未消费时才允许Epoch封装/接收，所有异步边界重新检查状态。原始Epoch/私钥只进SecretStore，普通配置和成员文件只放公开材料/密文。
- 签名成员事件必须验证既有信任锚与签发权限；members文件按签发者拥有路径，事件subject不能冒充文件写者。成员/撤销归约与Epoch轮换先单独验收，再把名单传给codec；文件自带公钥不能自行成为可信成员。
- S5.8 B/C1基础完成：不可变双端公开材料与规范transcript、身份完整指纹/UTC十分钟期限前后复核、X25519+HKDF独立32字节加密/确认材料及24bit短码。8项定向及完整core669、core分析GREEN；内部模块尚未接旧配对骨架/网络/App，没有Epoch交换入口。双方确认/签名会话/一次性QR、成员验证与安全落盘仍待C2–F；App最近S5.7回归257及分析通过。
- C2消息边界：QR邀请含发起者完整公开材料、随机session/nonce、UTC期限、一次性32字节秘密及其Ed25519签名；应答签名绑定完整双端transcript且不回传秘密。严格字段集合/类型、规范base64url及UTC日期，先复制解析再异步核验。
- C2生命周期：本机创建的邀请仅接受一次应答，取消/过期及异步核验后均复查；对端解析的QR不能冒作本机发起邀请。确认凭据为绑定完整transcript与确认方身份的HMAC，拒绝自反射/错会话/坏凭据；只有本机短码确认和对端确认都完成才ready，Epoch交换留D，不由接收消息自动触发。
- S5.8 C2完成：严格wire2项、签名邀请6项、签名应答5项、会话工厂/不可逆过期6项、双方确认8项共27项新验收GREEN；全部identity35项、完整core699与严格core分析GREEN。观察到过期后时钟回拨不能复活，取消在异步签名/核验/HMAC后均复查；凭据排队前冻结，Mac常数时间比较，重复确认不重发且不毒化队列。
- C2仍仅内部模块，尚无Epoch交换/成员信任落盘/网络或App接线；原PairingSession/Coordinator骨架未冒作生产服务。执行偏差：邀请初稿单次新增53行超限已如实记录，此后补丁强制工具侧预计数、超过50拒绝应用；App最近完整回归257及分析通过。
- D封装边界：复用VaultKey与XChaCha20，只有ready发起方可seal、ready应答方可open；AAD绑定完整transcript及固定发送/接收身份，严格头与最多256字节密文帧。Epoch号和32字节密钥仅在认证密文内，解封返回不可变内存VaultKey，E/F完成前不启用成员。
- D消费边界：成功发送/接收后会话completed并丢弃会话材料/关闭邀请，不可重新封装或再解封；网络重试只能缓存原密文。未ready或本机参数错误不消耗会话；格式/认证失败、取消与观察过期终止，异步加解密后复查再返回，内部JSON/异常不可泄露明文密钥。completed仅表示核心交换结束，不等同已保存或已配对。
- S5.8 D完成：10项Epoch确认/角色/单次消费/输入冻结/乱序/篡改/跨会话/严格wire/有效AEAD坏明文/异步取消过期验收GREEN，完整core709及严格core分析GREEN。解封仅返回不可变内存VaultKey，未做SecretStore落盘/成员启用/真实网络或App接线；App最近完整回归257及分析通过。下一项E成员验证/撤销轮换，再F假存储落盘。
- C2/D独立只读安全复核未发现可证实P0/P1/P2阻塞，独立复跑45项配对测试全部通过；范围仅五个配对模块及密码学依赖，不覆盖E/F、HTTPS/App或真实存储，不能替代S5.11整体验收。
E1权威源核对（只读）：
- 原件《序点_SeqPoint_PRD_V1.1_零服务端业务存储架构.docx》§10.4 P680–684/§11.3 P802–806：已有可信设备签DEVICE_ADDED，任一当前可信设备可签DEVICE_REVOKED；新Epoch仅给未撤销设备，收到撤销后拒绝旧设备后续会话，不设owner独占权限。P号按word/document.xml中全部w:p计数，旧Markdown章节引用有漂移。
- 原件§10.3 P662–675/§12.1 P858–860未给出创始可信锚/授权链格式、成员前序或授权版本；业务字段HLC排序不直接成为成员授权规则。并发加入/撤销/同Epoch分叉轮换与撤销前历史迟到界限均未明示，E2需明确保守规则再编码，不能默认信任文件公钥或任选分叉密钥。
- 同步V1的单写者members文件按本计划已裁定归签发者，subject不能冒充写者；当前MembershipEvent/KeyRotation仍DTO/接口、codec静态名单不能独自表达撤销边界。此项是待设计实施，不是需要真实设备或用户确认的外部阻塞。
- E2规则已固化于[成员签名与Epoch生命周期](../specs/2026-10-26-signed-membership-policy.md)：任一可信成员授权、显式可信锚、父状态授权/分叉fail-stop、会话检查点绑定、公开撤销先于密钥可用性及显式恢复隔离旧域。只读设计复核提出的三项边界已纳入，不能宣称消除旧私钥补签造成的可用性影响。
- E原子队列：成员公钥/承诺→可信初态与签名事件/父授权→乱序/分叉/撤销→Epoch封装/接收者/可用性→配对检查点绑定→F假存储及文件/会话接线。自撤销首版收窄与缺截止历史等待均明示，完整App启用仍晚于后续验收。
- E3基础完成：复用Ed25519验签器的无私钥静态入口/异步输入复制、不可变MemberKeys/严格wire/完整指纹与验签、Vault作用域密钥承诺。新增7项、相关10项定向及完整core716/App257与两层分析GREEN，承诺与Python hashlib独立黄金值一致。只证明公开材料与密钥一致性，不授予成员权限；E4签名事件/父授权及E5–F仍待完成。
- E4a初态完成：MembershipState私有构造/final，只能由本机持有DeviceKeys/VaultKey的createVault建立，随机授权域/排序规范公开hash与只读集合，不保存原始Epoch，不提供网络fromJson信任入口。3项新测试及完整core719/严格core分析GREEN；App最近E3回归257及分析通过。E3/E4a独立只读复核无可证实P0/P1/P2，独立13项定向GREEN；范围不含后续签名归约/检查点接收/SafeStore，整体同步仍未启用。
验证只用临时目录/假密钥/独立测试DB，不访问真实vault，不对用户数据做恢复或发往现有设备。
算法来源：[cryptography XChaCha20](https://pub.dev/documentation/cryptography/latest/cryptography/Xchacha20-class.html)、[Ed25519](https://pub.dev/documentation/cryptography/latest/cryptography/Ed25519-class.html)。先编译核对已有解析版本，不为算法重复引入依赖。

### 6. 后续实施分解规则
- [x] 阶段 5 首批本机协议/存储/服务/UI与真实TLS临时多实例验收完成，细项见P1/P2/C7/C8；后置通道/未知历史新协议不擅自扩范围，真实设备转P3。
- [x] 阶段 6 首批图片/短语音/录音播放导出/手动转写确认及AI纪要入口完成，主会话接入口/回归并独立审查；自动长转写未实现，真实权限/系统音频/保存转P3。
后续每阶段开始前把具体文件、接口、失败用例追加到本计划和 TODO；沿用已批准设计自行决定常规实现，不重复索取批准。
新依赖只在既有插件无法完成已授权需求时引入，并先核对官方文档。无真实密钥/设备时不能伪造端到端成功。

## 执行记录

2026-10-26 P1并行批次：成员/HTTPS/多媒体三个实现代理实际写代码；主会话补配对checkpoint认证绑定、完整控制事实与Epoch安全存储、公共导出和UI入口，另派独立审查。自动化seqpoint已切并行模式，不重复已完成阶段。
P1最终：完整core780/App285、两层严格分析、macOS debug编译与git diff --check均通过。独立安全103项及原4项P2复现全部closed（含跨进程swap 20,000次目录读取），独立多媒体31App+12core及范围严格分析通过。旧恢复屏障夹具已适配新String菜单，原屏障断言全部保留；本机模块交付不等于真实同步或真机验收，后续P2详见TODO。
P2阶段检查点：三实现代理完成有界成员wire/策略、无openssl的RSA2048/SHA256自签/PKCS12与假安全存储、音频播放/导出；root补仅published DB密文字节的可信catalog、接收器真实策略门与实际播放入口。完整core822/严格分析通过，独立成员/TLS/目录31项、接收器ACK38项通过；TLS多余ASN.1字段P2已真实复现/红绿修复。音频两项独立P2正修，App全回归/原生编译待该模块冻结，不能宣称整体同步已启用。
P2资源与范围：业务目录只缓存当前Epoch已认证版本，1000文件/64MiB上限、版本CAS与stop排空，缺key/撤销/恢复断开停传；旧Epoch无可信截止证明仅等待，不导入/ACK。可携带媒体/加密备份继续按原设计§3后置，不将未请求的新备份格式增为本批交付；真机与端到端服务/配对UI仍未验。
P2最终验证：完整core822/App312、两层严格Dart分析、macOS debug/iOS simulator debug编译、git diff --check全部通过。音频两项P2已补6条回归并由独立代理21项复测关闭；接收器授权与ACK独立38项、成员/TLS/目录独立31项通过。iOS编译不等于PKCS12原生运行/真实音频验收；下一步优先成员facts持久与控制目录、App主引擎/配对与最终ACK同步gate，详见TODO P2-C2–C4。

P2-C本机集成（2026-10-26）：控制器安全写回读成功后才激活，members目录仅用已持久验证的自有事实；更新期间业务/控制鉴权阻断，keyless已验证成员仍可取得控制。HTTPS运行时先控制后业务，ACK原子发布前同步复核当前授权、DB/水位及实际暂存bytes；超时后原始签名/请求任务也须排空。
主引擎独占App服务，准备本机/建空间/监听/同步均显式点击；人工交换有用途/尺寸/期限限制的配对码，双方短码核对后才交付并安全保存。AppScope暴露服务与提交后revision，恢复/退出排空后才关旧库；子便签无第二个同步服务。接口约定详见`../specs/2026-10-26-sync-app-interface-design.md`。
想法role按原PRD从提醒/今日查询过滤，兼容旧角色而不误伤project/custom同名；远端提交后提醒对账失败不回滚业务，对账错误不毒化后续队列。停止错误在交付前清除Root/service失败缓存、保持closed并保留DB，允许再次清理，成功future继续幂等。
集成复核P1已关闭：v2同条安全记录兼容v1并保存逐Epoch承诺证明的历史key，旧published sealed目录真正认证；仅当前peer已有全部持久事实的精确旧段封口可补元数据/水位。未知/新增旧事实仍waiting，旧未发布prepared不以旧key继续发新业务；v1已丢失key不反推。
本批验证：主会话完整core862/App374与两层严格分析exit0，Root/恢复/对账27项、AppService16项通过；最终macOS debug/iOS simulator debug编译均exit0。独立控制/历史key/旧封口及Root/UI/停止复核均关闭已确认P1/P2，不将fake store/loopback或编译冒充真机。
下一批最小依赖：core明确恢复后新身份提交边界→安全identity/membership存储→service与配对恢复模式→UI；显式冲突恢复须新授权域/更高Epoch和双方确认，不能只加按钮。未知旧历史的可信初始化尚缺具体合同，先保留等待并准确展示，不能自行发明覆盖快照/水位或放宽鉴权。mDNS/云中转/Syncthing/可携带加密备份继续后置。

P2-C7实施合同（2026-10-26续）：core代理独占`sync_baseline.dart`与`sync_restore_identity_test.dart`，新增`initializeRestored(newDeviceId, previousDeviceId:)`，仅恢复flag/关闭/notready/无同步历史且新旧ID合法不同才可在同一事务绑定新writer、清flag并建立全业务基线；普通入口仍拒绝恢复flag。旧ID由App已安全保存的身份提供，core不声称能证明私钥已安全生成。
核心失败用例：同ID/非法ID/非恢复或旧同步历史拒绝，基线写失败全回滚，双连接仅看到完整提交，重开保持新writer。非恢复入口不增加宽松fallback；DB已提交后App按writer匹配安全身份恢复，不重复执行恢复事务。
App代理独占`sync_identity_store.dart`、必要的`sync_tls_store.dart`、成员安全存储及`app_sync_service.dart`/part与专属测试；先安全写入并回读全新身份/TLS/已完成双方确认的配对控制，再调用core提交，旧私钥/控制审计不删。须覆盖DB提交前后崩溃、重复恢复和安全保存失败，具体记录格式冻结后追加。
UI代理独占同步设置/配对页与专属测试；先完成真实`waitingPeers`完整ID展示（Outcome未含原因/名称，不推断），再按冻结的service合同接恢复流程；不改Root/共享记录，不直接清DB或创建信任锚。Flutter由root授予执行窗口，core定向可并行。
身份格式冻结：v2仅保存`{v:2,identities:[完整v1材料…]}`并追加历史；按DB writer精确选择，无writer且恢复flag存在时仅展示最近身份，不自动启用或复用候选。容量/条数写前拒绝、不裁剪；新身份成员记录按ID独立安全key，旧默认记录仅身份匹配时兼容，TLS沿用已安全核验材料与新签名transcript绑定。
服务合同冻结：`beginIdentityRecovery(name)`、`respondToRecoveryInvitation(payload)`、`finishIdentityRecovery(session,packet)`，以及requiresNewIdentity/hasPendingIdentityRecovery/pendingIdentity/hasMembershipConflict状态；普通newVault/配对入口不绕过恢复flag。已有writer缺对应安全身份/控制记录时关闭，不退回旧key。
host冲突闭环由core代理独占`identity/membership_state.dart`、`membership_reducer.dart`及独立host恢复测试：新增`fromHostedPairing`/`recoverFromHostedPairing`，仅completed initiator，guest原入口继续拒host；复用同Vault/新域/更高Epoch/未复用承诺/双方完整身份与checkpoint hash验证，旧facts/pending/isolated完整保留。
App代理负责Store/controller host转发及候选临时状态：现有createVault可指定maxObserved+1的VaultKey，host自有新锚+签add guest，仅真实双方ready并seal绑定检查点后才验证/安全保存，回读成功才交付原envelope。未完成/错角色/换hash或身份/旧域/低Epoch/旧key均须拒绝，显式流程不可由普通成员文件触发。
P2-C8需求核对：原始PRD V1.1 P1042–1046的AC-008设备撤销为P0，P802允许任一当前可信成员发起；同步V1第62行/任务清单V2第131行将Epoch轮换绑定撤销。撤销未被后置，须在C7后补App service/独立part与设置确认入口，复用core签名撤销/精确剩余接收者/安全回读；没有独立手动rotate按钮必交付原文，不据协议能力追加产品功能。真机与已后置搬运通道不冒充验收。
C8文件/接口冻结：新代理独占App主service的part/getter/公开转发、新`app_sync_service_revocation.dart`与专属test；提供`membershipVersion`及`revokePeer(MemberKeys expectedPeer, expectedVersion:)`。UI独占设置页/专属test，以完整目标身份及确认前的版本作固定输入，取消确认不操作，过期确认必须重试。
撤销必须当前private成员控制ready、当前key/DB writer及基线匹配，非恢复/冲突且目标为另一active成员；任何可信成员均可发起，不增加owner。签名await后再核版本/实例/父head/完整target与DB，使用core原有fresh新Epoch及精确剩余封装，再追加安全自有members文件交controller.ingest，读回成功前不得激活。
C8故障验收：非founder撤另一peer、拒self/陌生/换key或旧确认、写/回读失败停传、撤销后TLS旧peer拒绝且其余成员取新key；媒体bytes/旧段/业务与Outbox保留，不清理历史。C7整体验证完成前C8仅准备不改文件，Flutter窗口仍由root调度。
C7最终主会话证据：core884/App396、两层完整严格分析、macOS debug/iOS simulator debug均exit0；独立core22项/五文件分析及App/恢复UI静态终审无剩余P1/P2。服务/安全存储63项、UI23项GREEN包含post-DB/缺记录/重读失败/在途host与离页取消等真实RED→GREEN；仅测试密钥/临时DB/loopback，不冒充真机。C8已在此冻结基线上放行两代理实现。
C8最终：撤销服务9项/原服务恢复35项、UI8项/设置恢复22项GREEN；非founder经真实TLS撤创始成员、被撤peer拒绝、剩余peer取新key，写/回读失败不激活、签名await内stop/writer/restore变化不写、安全记录/Outbox/媒体不清理。确认保留原完整peer/token，旧确认拒绝而不自动重试。
主会话实审代码后完整App413、完整App严格分析、macOS debug/iOS simulator debug与git diff --check全部exit0；core在C7后未变，最近完整884/严格分析仍有效。独立C8服务/Settings审查未发现确认P0/P1/P2，未提交/推送/远端合并/发布。
六阶段首批本机交付收口：只读清单核对未发现C8后另一个当前必做功能；历史E5/旧总路线/多媒体聚合TODO已按证据收口，不能重做。未见证旧历史继续waiting/noACK，独立rotate、云Syncthing/mDNS、携带加密备份等后置，自动长转写不写成已实现。
P3外部条件：Mac进程86869仍运行，按既有边界不强停/不启动独立入口/不读生产key；关闭后才UUID隔离键实测。Windows/通知精度与重启/文件提供方/真实模型计费/双设备TLS局域网后台/语音识别录音另存仍未通过。自动化保持外部跟踪、无变化静默，全部实际验收完成后再停止。
P3.1条件已由用户解除：用户关闭SeqPoint且pgrep无生产进程。root独占临时`apps/seqpoint_app/tool/keychain_probe.dart`与Flutter窗口：仅初始化Flutter binding/真实SecureSecretStore，不导入生产main/Bootstrap；随机UUID键确认不存在后才归本次所有，固定非secret值写/读/覆盖/删，finally只清理本次键并核对read=null/contains=false，日志不输出值/原始异常。
隔离入口显式exit退出（Mac AppDelegate关窗不自动退出），串行`flutter run -d macos --debug --no-pub -t tool/keychain_probe.dart`；若失败记录native状态，不把构建当通过。完成后删除临时入口并`flutter build macos --debug --no-pub -t lib/main.dart`恢复生产产物，检查无本次进程残留及git差异；其余可执行项再按TODO核对，不读取生产keys或用户DB。
P3.1原生启动遇到新阻塞：直接Flutter子进程与UI读取触发的LaunchServices进程均仅单线程停在dyld/libSystem→_libsecinit_appsandbox→XPC，暂停取样确认Dart main尚未执行后仅清理本次探针进程；没有运行Keychain测试，不把它记为失败或通过。临时入口已删除，生产main重建中，不调整沙箱/权限或用户容器。
可独立继续的系统层验收使用临时`.codex/keychain_system_probe.py`调用系统`security`，只查询新UUID service/account，确认不存在才写固定非secret测试值，跨命令读取/覆盖/精确删除/finally缺失复核。该结果仅代表系统默认Keychain通路，不能替代SeqPoint真实适配器或Data Protection Keychain验收；完成后移除脚本。
P3.1本轮结果：系统默认Keychain以UUID 75128dfb-da7d-4f0a-928f-5789e3de48ee完成全部检查/精确finally清理，脚本exit0；独立再次查询同service/account exit44，条目确认不存在。系统层已通过，SeqPoint沙箱适配器尚未运行，不把前者冒充后者。
Native阻塞现场保留在`/tmp/seqpoint-keychain.29Y65c`及`/tmp/seqpoint-keychain-native-paused.txt`、`/tmp/seqpoint-keychain-launchservices-paused.txt`；本次PID56653/56770暂停取样均只有dyld/libSystem→_libsecinit_appsandbox→XPC线程，确认尚未进入Dart后只清理本次进程。需新的系统诊断/条件变化证据才续测，不在心跳中盲重启，也未调沙箱/权限/用户容器。
临时两脚本已移除，`flutter build macos --debug --no-pub -t lib/main.dart`exit0，生成配置实际FLUTTER_TARGET=lib/main.dart；未再启动生产App。设备条件实查仅Mac/Chrome、已安装Simulator runtime=0/无Android AVD，不下载或触及既有Simulator数据。其余真机/模型配置仍待条件，自动化继续静默跟踪。
P3.1新诊断：secinitd原始日志明确K29Y36X47U/com.seqpoint.seqpointApp开发签名不在现有容器ACL（旧记录validationCategory=none），系统当时发起提示；随后10-26 18:58日志记录同意该签名访问容器及metadata更新。旧容器是否来自FQ3没有证据，不能据团队切换臆断。此系统条件变化满足续测门槛，现有容器不删除/迁移，不由代理点击额外权限。
续测仅重建独立native入口：新UUID键先确认不存在才own，固定测试值写/读/覆盖/删并finally核验缺失，完整等待所有原生Future；测试完成后周期输出脱敏结果直到runner受控关闭，避免早期stdout丢失。检测系统弹窗时按权限范围由用户处理；最终删临时入口、重建lib/main.dart并记录实际结果。
P3.1最终：secinitd日志定位签名身份不在旧容器ACL及后续系统同意，新条件下一次macOS native运行真实SecureSecretStore：UUID f9e7096d-f1ab-4657-bd60-838609f2ead7缺失/写/读/覆盖/删除及finally再次删除/缺失均PASS，Flutter runner exit0。当前依赖flutter_secure_storage 10.3.1/Darwin 0.3.2源码确认macOS默认使用Data Protection Keychain；非Secure Enclave。
root核对日志/代码/依赖，独立代理复核探针边界与选项；临时50行入口移除、生产lib/main.dart macOS debug构建exit0、FLUTTER_TARGET及进程清理确认。诊断空白窗口的runner报告前台激活失败，未声称生产GUI已验；锁屏/设备重启后首次解锁、iCloud及其他设备行为也未验。
P3.2条件推进：现有Mac沙箱可进入Dart，两个代理分文件准备临时原生检查模块，root独占组合入口与Flutter串行运行。TLS仅新内存测试密钥、签名成员及可信内存bytes，校验真实127.0.0.1正确pin/错误pin握手前拒绝/撤销后当前授权拒绝，finally排空关闭；不扫描文件、不用无条件证书回调或生产DB/密钥。
通知只调用原生只读权限状态查询，不初始化请求权限、不枚举/安排/取消用户通知；窗口仅对本次probe窗口验证显隐桥，不打开子窗口/生产Bootstrap。均不能冒充双设备真实LAN、通知投递精度、系统权限交互或生产GUI验收；先验证生产App未运行，结束仅清理本次临时文件/进程并重建生产main。
P3.2本机部分PASS：secinitd确认probe PID85248的AppSandbox request successful；真实127.0.0.1 TLS正确pin/错误pin握手前拒绝/撤销后当前授权拒绝均通过，服务与客户端完成排空。只读通知结果enabled/alert/sound/badge/provisional均false，无法区分未请求或拒绝；探针自身窗口show/hide/show可见性通过，不代表真实投递、焦点/托盘/热键或双设备LAN通过。
三个临时文件/探针进程已清理（最长92行helper按42+50行两次删除、间隔单文件strict分析），生产lib/main.dart macOS debug构建exit0、FLUTTER_TARGET核对通过。Flutter工具对空白探针的`open`前台激活返回1但未输出stderr，生产GUI焦点仍未验；未读业务DB/keys、修改系统权限或操作用户通知。
成员代理专项21项、identity74项与HTTPS18项定向通过；独立审查复跑92项与App安全存储4项通过，最终审查尚在进行。成员控制记录保留可信锚/签名facts/pending/分叉及旧域隔离审计；只保存最新名单不足以重启后识别旧父分叉。
图片复用v3附件表/file_picker/path_provider；语音复用新核验speech_to_text7.5.0（短句），会议录音record7.1.2，pub get通过；iOS/macOS说明与audio-input、Android麦克风/识别查询已逐文件校验。真实权限/系统识别/录音未验收，不能冒充连续会议转写。
图片预览widget两次等待调整失败已熔断；独立诊断证实FutureBuilder在fake zone启动多段真实I/O，固定等待无法解锁；按实际readiness Future验证，尚未计图片UI交付。期间Flutter native assets并发发生复制失败，App Flutter测试已统一独占执行，core定向可并行。

2026-10-25：用户批准推荐设计与自动执行；选用当前会话顺序实施。因当前未提交桌面改动是后续基础，保留当前目录并创建 `codex/next-stages`，不复制或重置工作区。
排期按工作量估算，自动续做只在有可执行工作时推进；相同阻塞不刷屏，全部交付完成后停止续做。

2026-10-25 检查点：阶段 2 独立审查发现的 iOS 代理、系统队列恢复、iOS 64 条上限已处理；Windows 先撤销原 ID 再安排。最终 core 241/app 143 测试通过，静态分析无问题，macOS debug 与 iOS simulator debug 构建通过。下次从阶段 3 的快照安全预检开始，不重复实现阶段 2。

2026-10-25 阶段3本地交付检查点：恢复全链路、可见保护、回滚/启动恢复与明文导出均完成，最终core307/app199、分析及macOS/iOS模拟器构建通过。列表明示SQLite/未校验，确认展示只读校验结果及文件修改时间。真机边界保持未验收；自动化继续阶段4，不重做阶段3。

历史导出检查点（已被上述阶段3最终结果更新）：唯一手动快照、JSON过滤、Markdown完整性/链接和跨平台保存接线完成时，core298/app161及两平台构建通过；当时尚待立即备份/恢复UI，现已完成。真机文件提供方仍未验收。
