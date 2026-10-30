# 序点 SeqPoint

> 让每件事，都有顺序。

一个跨设备的智能便签：想到就记，AI 把便签整理成带标签、带提醒的待办，
盯着你完成；做完了，像揭走一张便签纸一样关闭。

## 仓库结构

```text
apps/seqpoint_app          Flutter 应用（Android / iOS / macOS / Windows）
native/syncthing           内嵌 Syncthing 引擎、移动端桥接及许可证收集
packages/seqpoint_core     核心层：纯 Dart，数据 / 业务 / AI / 提醒 / 同步
packages/seqpoint_platform 平台能力接口：快捷键 / 托盘 / 窗口 / 通知 / 安全存储
node                       个人云中转：Go 签名文件 API + Caddy + Docker Compose
scripts                    密钥扫描、本地 CI
docs                       设计文档、决策记录、实施计划
```

## 文档

- 产品设计：`序点 SeqPoint 产品设计 V2.2（初心先行 · 双端并行 · 可选云中转）.md`
- 同步架构：`序点 SeqPoint 同步架构方案 V1（基于 Syncthing 协议）.md`
- 任务清单：`序点 SeqPoint 任务清单 V2（设计 V2.2 + 同步方案 V1）.md`
- 环境准备：`docs/开发环境准备清单.md`
- 局域网配对与 NAS 跨网同步：[设备同步](docs/device-sync.md)
- 应用内下载与安装更新：[完整版本更新](docs/full-version-updates.md)
- 云中转部署与容量边界：[node/README.md](node/README.md)
- 决策记录：`docs/decisions/`

## 开发

```bash
flutter pub get
bash scripts/ci_local.sh                   # 全量检查
```

构建客户端前，在仓库根目录生成对应平台的原生同步引擎：

```bash
bash native/syncthing/build-engine.sh macos # 或 android / ios / windows / linux
python3 native/syncthing/collect_licenses.py
cd apps/seqpoint_app
flutter build macos                       # 按平台使用对应 Flutter 构建命令
```

脚本从 `native/syncthing/go.mod` 使用固定 Go 工具链。Android 还需要 NDK
28.2.13676358；iOS/macOS 需要 Xcode。CI 会安装依赖并生成原生引擎，
不将生成的 AAR、XCFramework 或可执行文件提交到仓库。
