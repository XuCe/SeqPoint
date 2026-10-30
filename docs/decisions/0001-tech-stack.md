# ADR-0001 技术栈：Flutter 单代码库覆盖四端，核心逻辑纯 Dart

- 状态：已采纳（2026-09-03）
- 相关：产品设计 V2.2 修订 2、同步架构方案 V1 修订 1

## 背景

手机端与桌面端并行交付；主测机 Android；开发机 macOS，另有 Windows 机；
Web 端另行考虑。同步要求"官方基础设施全部自建"且首版安装包不能臃肿。

## 决定

1. Flutter 3.47.2 / Dart 3.13，平台为 `android,ios,macos,windows`，**不生成 web**。
2. pub workspace 单代码库三包：
   - `apps/seqpoint_app`：四端 UI 与平台实现装配；
   - `packages/seqpoint_core`：纯 Dart，无 Flutter 依赖，可在主机跑单测；
   - `packages/seqpoint_platform`：平台能力接口，实现按端注入。
3. 本地库 sqlite3（后续切 SQLCipher 做静态加密）；密钥仅入系统安全存储。
4. 加密原语用 cryptography 包（Ed25519 / X25519 / XChaCha20-Poly1305），
   与 PRD V1.1 附录 A 一致；Rust 仅在 M4 性能不足时引入。
5. 同步不同步数据库，而是同步"单写者加密文件"目录；精简通道内置，
   Syncthing 引擎按需获取。

## 后果

- 平台差异必须封装在 `seqpoint_platform`，缺失能力返回 null 而非抛异常；
- 任何需要 web 的需求先回到产品层重新评审；
- 核心层不得 import Flutter，以保证单测可在主机直接运行。
