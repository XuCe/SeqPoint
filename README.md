# 序点 SeqPoint

> 让每件事，都有顺序。

一个跨设备的智能便签：想到就记，AI 把便签整理成带标签、带提醒的待办，
盯着你完成；做完了，像揭走一张便签纸一样关闭。

## 仓库结构

```text
apps/seqpoint_app          Flutter 应用（Android / iOS / macOS / Windows）
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
- 设备同步（同步网关 + 从已连接设备加入）：[设备同步](docs/device-sync.md)
- 应用内下载与安装更新：[完整版本更新](docs/full-version-updates.md)
- 云中转部署与容量边界：[node/README.md](node/README.md)
- 决策记录：`docs/decisions/`

## 开发

```bash
flutter pub get
bash scripts/ci_local.sh                   # 全量检查
```

客户端直接用 Flutter 构建，不需要额外的原生同步引擎：

```bash
cd apps/seqpoint_app
flutter build macos                       # 按平台使用对应 Flutter 构建命令
```

iOS/macOS 需要 Xcode，Android 需要 JDK 17。同步网关在 `node/` 下单独用 Go 构建，
见 [node/README.md](node/README.md)。
