# 序点 SeqPoint M0–M1 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成 M0（立项与预研：仓库骨架、五项 PoC、设计基线、决策门）并给出 M1（双端随手记闭环）的任务级分解，让后续实现在一个 Flutter 单代码库里同期覆盖 Android / iOS / macOS / Windows。

**Architecture:** 单代码库 pub workspace：`apps/seqpoint_app`（Flutter 四端壳与界面）+ `packages/seqpoint_core`（纯 Dart：数据模型、便签⇄事项状态机、规则解析、同步引擎，可在主机上跑单测）+ `packages/seqpoint_platform`（平台通道：全局快捷键、托盘、多窗口、通知、选中文字读取）。M0 的每个 PoC 都落在最终目录里，通过后直接演进为正式代码，不做丢弃式原型。

**Tech Stack:** Flutter 3.44 stable / Dart 3.12（pub workspaces）、sqlite3 + sqlite3_flutter_libs（M1 换 sqlcipher_flutter_libs）、flutter_secure_storage、cryptography（X25519 + XChaCha20-Poly1305）、nsd（mDNS）、LeanFlutter 桌面套件（hotkey_manager / tray_manager / window_manager / local_notifier）、desktop_multi_window、flutter_local_notifications、home_widget、receive_sharing_intent、quick_actions。

## Global Constraints

- 依据：《序点 SeqPoint 产品设计 V2.2（修订 1）》与《任务清单 V1》；同步与密钥工程细节以《PRD V1.1》第 11–12 章为准。
- 平台：Android（主测机）、iOS、macOS（开发机）、Windows；**Web 端不进入代码库**（`flutter create --platforms` 不含 web，CI 不构建 web）。
- 版本下限：Flutter ≥ 3.44.0 stable，Dart ≥ 3.12.0；Android minSdk 26；iOS 15；macOS 12；Windows 10 1809。
- 初心边界：M1–M3 只做随手记、一签多事项、AI 归纳与双维标签、智能提醒、完成即关；本计划不含会议模块（M6）与 Web。
- 安全红线（NFR-113/114）：任何密钥、Vault Key、Recovery Seed 不进 SQLite、配置文件、日志、崩溃报告、导出文件；`scripts/scan_secrets.sh` 在 CI 阻断。
- 性能：全局快捷键唤起便签 ≤ 300ms；冷启动 ≤ 2s；快速记录 3 秒内可保存。
- 产品原则：先记后整理；简单事项保持简单；AI 建议不接管（确认卡）；提醒以减少遗漏为目标；隐私默认开启（无账号、无遥测）。
- 语言：代码注释、提交信息、文档用简体中文；标识符英文。命令同时给出 macOS zsh 与 Windows PowerShell 版本。
- 提交：每个任务结束提交一次；提交信息前缀 `feat:` / `chore:` / `test:` / `docs:`。

---

## 环境前置（2026-09-03 在开发机实测）

| 项 | 状态 | 说明 |
|---|---|---|
| Flutter | ✓ 3.44.0 stable，`/Users/yiyi/development/flutter` | 有新版本提示，M0 期间不升级，避免 PoC 期间环境漂移 |
| Dart | ✓ 3.12.0 | 支持 pub workspaces |
| Xcode | ✓ 26.3（iOS / macOS 可构建） | |
| Java | ✓ OpenJDK 17.0.20 | 满足 Android Gradle 要求 |
| CocoaPods | ✓ 1.16.2 | 警告终端非 UTF-8：在 `~/.zshrc` 加 `export LANG=en_US.UTF-8` |
| Android SDK | ✗ 未安装，`adb` 不存在，`ANDROID_HOME` 未设置 | **由所有者按《docs/开发环境准备清单.md》自行安装**；任务 6 开始前必须就绪 |
| git | ✓ /opt/homebrew/bin/git | 目录尚未 `git init` |
| Windows 机 | 未在本次检查范围 | 任务 5 / 任务 9 的 Windows 步骤在 Windows 机上按 PowerShell 命令执行 |

---

## 仓库结构（M0 建立，M1 起沿用）

```text
SeqPoint/                                  # 仓库根（现有设计文档保留在根目录不动）
├── pubspec.yaml                           # pub workspace 根
├── analysis_options.yaml                  # 统一 lint
├── .gitignore
├── apps/seqpoint_app/                     # Flutter 应用（android / ios / macos / windows）
│   ├── lib/main.dart
│   ├── lib/app.dart                       # MaterialApp + 主题 + 平台分流
│   ├── lib/theme/seq_theme.dart           # 设计令牌 → ThemeData
│   ├── lib/poc/                           # M0 PoC 页面（M1 结束时删除）
│   │   ├── desktop_poc_page.dart          # 快捷键 / 托盘 / 多窗口 / 通知
│   │   ├── mobile_poc_page.dart           # 通知 / 小组件 / 分享 / Quick Actions
│   │   ├── secure_storage_poc_page.dart
│   │   └── lan_sync_poc_page.dart
│   ├── macos/Runner/SelectedTextPlugin.swift
│   └── windows/runner/selected_text_plugin.cpp
├── packages/seqpoint_core/                # 纯 Dart，无 Flutter 依赖
│   ├── lib/seqpoint_core.dart
│   ├── lib/src/db/database.dart           # 打开 / 迁移
│   ├── lib/src/db/migrations.dart         # v1 schema
│   ├── lib/src/model/{note,item,tag,reminder,activity}.dart
│   ├── lib/src/sync/{hlc,op_log,merge,lan_channel,crypto_session}.dart
│   └── test/…
├── packages/seqpoint_platform/            # 平台通道封装（M1 起）
├── scripts/scan_secrets.sh
├── docs/decisions/0001-tech-stack.md      # ADR
└── .github/workflows/ci.yml
```

模块边界：`seqpoint_core` 不 import Flutter；`seqpoint_app` 只通过 core 的公开 API 访问数据；平台能力全部经 `seqpoint_platform` 的抽象接口（`HotkeyService`、`TrayService`、`NotificationService`、`SelectedTextService`），便于在测试里替换。

---

## M0 · 任务 1：仓库与 workspace 骨架

**Files:**
- Create: `.gitignore`、`pubspec.yaml`、`analysis_options.yaml`
- Create: `apps/seqpoint_app/`（`flutter create`）、`packages/seqpoint_core/`（`dart create`）
- Create: `packages/seqpoint_core/test/smoke_test.dart`

**Interfaces:**
- Produces: workspace 根 `pubspec.yaml`（后续所有任务在其内 `pub get`）；`seqpoint_core` 包名与 `lib/seqpoint_core.dart` 入口。

- [ ] **Step 1: 初始化 git（需所有者确认后执行）**

```bash
cd /Users/yiyi/development/SeqPoint
git init -b main
cat > .gitignore <<'EOF'
.DS_Store
build/
.dart_tool/
.idea/
*.iml
**/pubspec.lock
!apps/**/pubspec.lock
**/.flutter-plugins*
**/ephemeral/
**/Pods/
**/xcuserdata/
*.env
*.key
EOF
```

PowerShell（Windows 机上克隆后无需重复 init）：`git clone <远端地址> SeqPoint; cd SeqPoint`

- [ ] **Step 2: 创建 Flutter 应用（不含 web）**

```bash
mkdir -p apps packages
flutter create apps/seqpoint_app --org com.seqpoint --project-name seqpoint_app --platforms=android,ios,macos,windows
```

预期：目录含 `android/ ios/ macos/ windows/`，**不含** `web/`。

- [ ] **Step 3: 创建纯 Dart 核心包**

```bash
dart create -t package packages/seqpoint_core --force
rm -f packages/seqpoint_core/lib/src/seqpoint_core_base.dart packages/seqpoint_core/test/seqpoint_core_test.dart
printf 'library seqpoint_core;\n' > packages/seqpoint_core/lib/seqpoint_core.dart
```

- [ ] **Step 4: 写 workspace 根 pubspec 与统一 lint**

```yaml
# pubspec.yaml（仓库根）
name: seqpoint_workspace
publish_to: none
environment:
  sdk: ^3.12.0
workspace:
  - apps/seqpoint_app
  - packages/seqpoint_core
```

```yaml
# analysis_options.yaml（仓库根）
include: package:lints/recommended.yaml
analyzer:
  errors:
    unused_import: error
linter:
  rules:
    - prefer_final_locals
    - avoid_print
```

在 `apps/seqpoint_app/pubspec.yaml` 与 `packages/seqpoint_core/pubspec.yaml` 的 `environment:` 之后各加一行 `resolution: workspace`；`apps/seqpoint_app/pubspec.yaml` 的 `dependencies:` 下加：

```yaml
  seqpoint_core:
    path: ../../packages/seqpoint_core
```

- [ ] **Step 5: 写冒烟测试（先失败）**

```dart
// packages/seqpoint_core/test/smoke_test.dart
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('core 包可被导入并暴露版本号', () {
    expect(coreVersion, '0.1.0');
  });
}
```

运行：`cd packages/seqpoint_core && dart pub add dev:test && dart test`
预期：FAIL，`coreVersion` 未定义。

- [ ] **Step 6: 最小实现**

```dart
// packages/seqpoint_core/lib/seqpoint_core.dart
library seqpoint_core;

/// 核心包版本，随 pubspec.yaml 的 version 同步。
const String coreVersion = '0.1.0';
```

运行：`dart test` → 预期 PASS。再在仓库根运行 `dart pub get && cd apps/seqpoint_app && flutter analyze` → 预期无错误。

- [ ] **Step 7: 提交**

```bash
git add -A && git commit -m "chore: 建立 pub workspace 骨架（seqpoint_app 四端 + seqpoint_core）"
```

---

## M0 · 任务 2：技术决策记录（ADR）

**Files:**
- Create: `docs/decisions/0001-tech-stack.md`

**Interfaces:**
- Produces: 后续所有任务引用的版本与平台基线。

- [ ] **Step 1: 写 ADR**

```markdown
# ADR-0001 技术栈：Flutter 单代码库覆盖四端，核心逻辑纯 Dart

- 状态：已采纳（2026-09-03，所有者确认）
- 背景：手机端与桌面端并行交付；主测机 Android；开发机 macOS，另有 Windows 机；Web 端另行考虑。
- 决定：
  1. Flutter 3.44 stable / Dart 3.12，`flutter create --platforms=android,ios,macos,windows`，不生成 web。
  2. pub workspace 单代码库：apps/seqpoint_app、packages/seqpoint_core（纯 Dart）、packages/seqpoint_platform。
  3. 本地库 sqlite3（M1 切换 sqlcipher_flutter_libs 做静态加密）；密钥仅入系统安全存储（flutter_secure_storage）。
  4. 加密原语用 cryptography 包（X25519 + XChaCha20-Poly1305），与 PRD V1.1 附录 A 一致；Rust 仅在 M4 性能不足时引入。
  5. 桌面平台能力用 LeanFlutter 套件与 desktop_multi_window；移动端用 flutter_local_notifications、home_widget、receive_sharing_intent、quick_actions。
- 后果：所有平台差异必须封装在 seqpoint_platform；任何需要 web 的需求先回到产品层重新评审。
```

- [ ] **Step 2: 提交**

```bash
git add docs/decisions/0001-tech-stack.md && git commit -m "docs: ADR-0001 技术栈决策"
```

---

## M0 · 任务 3：本地数据库 PoC（sqlite3，纯 Dart 可测）

**Files:**
- Create: `packages/seqpoint_core/lib/src/db/migrations.dart`
- Create: `packages/seqpoint_core/lib/src/db/database.dart`
- Modify: `packages/seqpoint_core/lib/seqpoint_core.dart`（导出）
- Test: `packages/seqpoint_core/test/db/database_test.dart`

**Interfaces:**
- Produces: `class SeqDatabase { static SeqDatabase inMemory(); static SeqDatabase open(String path); Database get raw; int get schemaVersion; void migrate(); void close(); }`；`const List<String> migrationsV1`。
- 后续 M1 的仓储层只依赖 `SeqDatabase.raw`（`package:sqlite3` 的 `Database`）。

- [ ] **Step 1: 添加依赖**

```bash
cd packages/seqpoint_core && dart pub add sqlite3 path && cd ../../apps/seqpoint_app && flutter pub add sqlite3_flutter_libs && cd ../..
```

- [ ] **Step 2: 写失败测试**

```dart
// packages/seqpoint_core/test/db/database_test.dart
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  setUp(() => db = SeqDatabase.inMemory()..migrate());
  tearDown(() => db.close());

  test('迁移后 user_version 为 1 且六张表存在', () {
    expect(db.schemaVersion, 1);
    final rows = db.raw.select(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
    final names = rows.map((r) => r['name'] as String).toList();
    expect(names, containsAll(['notes', 'items', 'tags', 'item_tags', 'reminders', 'activities']));
  });

  test('写入一条便签并读回', () {
    db.raw.execute(
      "INSERT INTO notes(id, kind, raw_content, status, created_at, updated_at) "
      "VALUES ('n1', 'text', '回复张三报价', 'active', '2026-09-03T09:00:00+08:00', '2026-09-03T09:00:00+08:00')");
    final row = db.raw.select('SELECT raw_content, status FROM notes WHERE id = ?', ['n1']).single;
    expect(row['raw_content'], '回复张三报价');
    expect(row['status'], 'active');
  });

  test('重复 migrate 不报错且版本不变', () {
    db.migrate();
    expect(db.schemaVersion, 1);
  });
}
```

运行：`cd packages/seqpoint_core && dart test test/db` → 预期 FAIL（`SeqDatabase` 未定义）。

- [ ] **Step 3: 写 v1 迁移**

```dart
// packages/seqpoint_core/lib/src/db/migrations.dart
/// v1：与产品设计 V2.2 第 9 章数据模型一致；时间戳存 ISO8601 文本，hlc 预留。
const List<String> migrationsV1 = [
  '''
  CREATE TABLE notes (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('text','meeting')),
    title TEXT,
    raw_content TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('active','closed')),
    color TEXT,
    pinned INTEGER NOT NULL DEFAULT 0,
    window_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    closed_at TEXT,
    deleted_at TEXT,
    hlc TEXT
  )''',
  '''
  CREATE TABLE items (
    id TEXT PRIMARY KEY,
    note_id TEXT REFERENCES notes(id),
    title TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('todo','done','canceled')),
    priority TEXT NOT NULL DEFAULT 'P4',
    due_at TEXT,
    completed_at TEXT,
    source TEXT NOT NULL DEFAULT 'manual',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    hlc TEXT
  )''',
  '''
  CREATE TABLE tags (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('project','type','custom')),
    builtin INTEGER NOT NULL DEFAULT 0,
    color TEXT,
    sort INTEGER NOT NULL DEFAULT 0
  )''',
  '''
  CREATE TABLE item_tags (
    item_id TEXT NOT NULL REFERENCES items(id),
    tag_id TEXT NOT NULL REFERENCES tags(id),
    PRIMARY KEY (item_id, tag_id)
  )''',
  '''
  CREATE TABLE reminders (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES items(id),
    mode TEXT NOT NULL CHECK (mode IN ('exact','relative','smart','overdue','digest')),
    trigger_at TEXT,
    offset_minutes INTEGER,
    is_strong INTEGER NOT NULL DEFAULT 0,
    snooze_count INTEGER NOT NULL DEFAULT 0,
    last_fired_at TEXT,
    feedback TEXT,
    enabled INTEGER NOT NULL DEFAULT 1
  )''',
  '''
  CREATE TABLE activities (
    id TEXT PRIMARY KEY,
    object_type TEXT NOT NULL,
    object_id TEXT NOT NULL,
    action TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT,
    created_at TEXT NOT NULL
  )''',
  'CREATE INDEX idx_items_note ON items(note_id)',
  'CREATE INDEX idx_items_due ON items(due_at)',
];
```

- [ ] **Step 4: 写数据库封装**

```dart
// packages/seqpoint_core/lib/src/db/database.dart
import 'package:sqlite3/sqlite3.dart';
import 'migrations.dart';

/// SQLite 封装：负责打开与按版本迁移。加密（SQLCipher）在 M1 通过替换 native 库接入，接口不变。
class SeqDatabase {
  SeqDatabase._(this.raw);
  final Database raw;

  static SeqDatabase inMemory() => SeqDatabase._(sqlite3.openInMemory());
  static SeqDatabase open(String path) => SeqDatabase._(sqlite3.open(path));

  int get schemaVersion =>
      raw.select('PRAGMA user_version').single.columnAt(0) as int;

  void migrate() {
    raw.execute('PRAGMA foreign_keys = ON');
    if (schemaVersion < 1) {
      raw.execute('BEGIN');
      for (final sql in migrationsV1) {
        raw.execute(sql);
      }
      raw.execute('PRAGMA user_version = 1');
      raw.execute('COMMIT');
    }
  }

  void close() => raw.dispose();
}
```

```dart
// packages/seqpoint_core/lib/seqpoint_core.dart
library seqpoint_core;

export 'src/db/database.dart';
export 'src/db/migrations.dart';

const String coreVersion = '0.1.0';
```

- [ ] **Step 5: 运行测试并提交**

运行：`dart test test/db` → 预期 3 个用例 PASS。

```bash
git add -A && git commit -m "feat(core): sqlite3 数据库封装与 v1 迁移（PoC）"
```

---

## M0 · 任务 4：系统安全存储 PoC（flutter_secure_storage）

**Files:**
- Create: `apps/seqpoint_app/lib/poc/secure_storage_poc_page.dart`
- Modify: `apps/seqpoint_app/macos/Runner/DebugProfile.entitlements`、`Release.entitlements`
- Modify: `apps/seqpoint_app/lib/main.dart`（临时把 PoC 页设为首页）

**Interfaces:**
- Produces: 约定密钥名 `ai.provider.claude.apiKey`；M2 的 `SecretStore` 接口以此 PoC 为基础：`Future<void> write(String key, String value)`、`Future<String?> read(String key)`、`Future<void> delete(String key)`。

- [ ] **Step 1: 添加依赖与 macOS 权限**

```bash
cd apps/seqpoint_app && flutter pub add flutter_secure_storage && cd ../..
```

两个 entitlements 文件的 `<dict>` 内各加入（Keychain 共享组，macOS 必需）：

```xml
<key>keychain-access-groups</key>
<array>
  <string>$(AppIdentifierPrefix)com.seqpoint.seqpointApp</string>
</array>
```

- [ ] **Step 2: 写 PoC 页面**

```dart
// apps/seqpoint_app/lib/poc/secure_storage_poc_page.dart
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _kKey = 'ai.provider.claude.apiKey';

class SecureStoragePocPage extends StatefulWidget {
  const SecureStoragePocPage({super.key});
  @override
  State<SecureStoragePocPage> createState() => _SecureStoragePocPageState();
}

class _SecureStoragePocPageState extends State<SecureStoragePocPage> {
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final _ctrl = TextEditingController();
  String _status = '未读取';

  String _mask(String? v) =>
      (v == null || v.length < 8) ? '(空)' : '${v.substring(0, 3)}…${v.substring(v.length - 4)}';

  Future<void> _write() async {
    await _storage.write(key: _kKey, value: _ctrl.text);
    setState(() => _status = '已写入：${_mask(_ctrl.text)}');
  }

  Future<void> _read() async {
    final v = await _storage.read(key: _kKey);
    setState(() => _status = '读到：${_mask(v)}');
  }

  Future<void> _delete() async {
    await _storage.delete(key: _kKey);
    setState(() => _status = '已删除');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('PoC · 安全存储')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(controller: _ctrl, obscureText: true,
                decoration: const InputDecoration(labelText: '模拟 API Key')),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              FilledButton(onPressed: _write, child: const Text('写入')),
              OutlinedButton(onPressed: _read, child: const Text('读取')),
              TextButton(onPressed: _delete, child: const Text('删除')),
            ]),
            const SizedBox(height: 12),
            Text(_status),
          ]),
        ),
      );
}
```

- [ ] **Step 3: 在 macOS 与 Android 上验证**

```bash
cd apps/seqpoint_app && flutter run -d macos     # 写入 → 完全退出 App → 再启动 → 读取仍能读到
flutter run -d <android 设备 id>                  # 同上（需先完成《开发环境准备清单》步骤 A/B）
```

验收：重启后可读；界面只显示脱敏值；在 macOS 用下面命令扫描应用容器，确认不存在明文：

```bash
grep -rl "sk-test-1234" ~/Library/Containers/com.seqpoint.seqpointApp 2>/dev/null; echo "exit=$? (1 表示未找到，符合预期)"
```

- [ ] **Step 4: 提交**

```bash
git add -A && git commit -m "feat(app): 安全存储 PoC（Keychain / Keystore）"
```

---

## M0 · 任务 5：桌面能力 PoC（全局快捷键 / 托盘 / 多窗口 / 通知）

**Files:**
- Create: `apps/seqpoint_app/lib/poc/desktop_poc_page.dart`
- Create: `apps/seqpoint_app/assets/tray/tray_icon.png`（22×22 模板图，黑色三点）、`assets/tray/tray_icon.ico`（Windows）
- Modify: `apps/seqpoint_app/lib/main.dart`、`apps/seqpoint_app/pubspec.yaml`（assets）

**Interfaces:**
- Produces: 平台能力可行性结论与延迟数据；M1 的 `HotkeyService` / `TrayService` / `WindowService` / `NotificationService` 接口签名以本页函数为原型：`Future<void> registerToggleHotkey(VoidCallback onToggle)`、`Future<void> showTray(List<TrayMenuItem> items)`、`Future<int> openStickyWindow(String noteId)`、`Future<void> notify(String title, String body)`。

- [ ] **Step 1: 添加依赖与资源**

```bash
cd apps/seqpoint_app && flutter pub add hotkey_manager tray_manager window_manager desktop_multi_window local_notifier && cd ../..
```

`pubspec.yaml` 的 `flutter:` 下加：

```yaml
  assets:
    - assets/tray/
```

- [ ] **Step 2: 改 main.dart 支持子窗口入口**

```dart
// apps/seqpoint_app/lib/main.dart
import 'dart:io';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'poc/desktop_poc_page.dart';

bool get isDesktop => Platform.isMacOS || Platform.isWindows;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.firstOrNull == 'multi_window') {
    // 子窗口：args[1] 是窗口 id，args[2] 是主窗口传来的参数（便签 id）
    final noteId = args.length > 2 ? args[2] : '';
    runApp(MaterialApp(home: Scaffold(body: Center(child: Text('便签子窗口 $noteId')))));
    return;
  }
  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true); // 关窗即隐藏，进程常驻
  }
  runApp(const MaterialApp(home: DesktopPocPage()));
}
```

- [ ] **Step 3: 写 PoC 页面**

```dart
// apps/seqpoint_app/lib/poc/desktop_poc_page.dart
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';

class DesktopPocPage extends StatefulWidget {
  const DesktopPocPage({super.key});
  @override
  State<DesktopPocPage> createState() => _DesktopPocPageState();
}

class _DesktopPocPageState extends State<DesktopPocPage> with TrayListener, WindowListener {
  final _log = <String>[];
  final _toggleKey = HotKey(key: PhysicalKeyboardKey.space, modifiers: [HotKeyModifier.alt], scope: HotKeyScope.system);

  void _add(String s) => setState(() => _log.insert(0, '${DateTime.now().toIso8601String().substring(11, 23)} $s'));

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _setup();
  }

  Future<void> _setup() async {
    await hotKeyManager.unregisterAll();
    await hotKeyManager.register(_toggleKey, keyDownHandler: (_) async {
      final sw = Stopwatch()..start();
      if (await windowManager.isVisible()) {
        await windowManager.hide();
        _add('⌥Space → 隐藏');
      } else {
        await windowManager.show();
        await windowManager.focus();
        _add('⌥Space → 显示，耗时 ${sw.elapsedMilliseconds}ms（目标 ≤300）');
      }
    });
    await trayManager.setIcon(Platform.isWindows ? 'assets/tray/tray_icon.ico' : 'assets/tray/tray_icon.png', isTemplate: true);
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '打开序点'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]));
    await localNotifier.setup(appName: 'SeqPoint');
    _add('初始化完成');
  }

  Future<void> _openSubWindow() async {
    final w = await DesktopMultiWindow.createWindow('note-demo');
    await w.setFrame(const Offset(200, 200) & const Size(280, 220));
    await w.setTitle('便签');
    await w.show();
    _add('子窗口 id=${w.windowId}');
  }

  Future<void> _notify() async {
    final n = LocalNotification(title: '序点', body: '"服务器证书续期"今天 18:00 到期');
    n.onClick = () => _add('通知被点击');
    await n.show();
    _add('通知已发送');
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem item) async {
    if (item.key == 'show') { await windowManager.show(); }
    if (item.key == 'quit') { await windowManager.destroy(); }
  }
  @override
  void onWindowClose() async { await windowManager.hide(); _add('关闭 → 隐藏（进程常驻）'); }

  @override
  void dispose() { trayManager.removeListener(this); windowManager.removeListener(this); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('PoC · 桌面能力')),
        body: Column(children: [
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: _openSubWindow, child: const Text('开子窗口')),
            FilledButton(onPressed: _notify, child: const Text('发通知')),
            OutlinedButton(onPressed: () => windowManager.setAlwaysOnTop(true), child: const Text('置顶')),
          ]),
          Expanded(child: ListView(children: [for (final l in _log) ListTile(dense: true, title: Text(l))])),
        ]),
      );
}
```

- [ ] **Step 4: macOS 验证**

```bash
cd apps/seqpoint_app && flutter run -d macos
```

验收清单（逐条记录到 `docs/decisions/0002-desktop-poc.md`）：① 切到其他应用按 `⌥Space` 窗口显示/隐藏，日志耗时 ≤300ms；② 菜单栏出现三点图标，菜单可用；③ 子窗口可开且可拖动；④ 系统通知弹出并可点击；⑤ 点红色关闭按钮后进程仍在（托盘可再打开）。

- [ ] **Step 5: Windows 验证（Windows 机，PowerShell）**

```powershell
cd apps\seqpoint_app; flutter run -d windows
```

同一清单，快捷键为 `Alt+Space`（若与系统窗口菜单冲突，改注册 `Alt+Shift+Space` 并记录到 ADR-0002，作为 Windows 默认值）。

- [ ] **Step 6: 提交**

```bash
git add -A && git commit -m "feat(app): 桌面能力 PoC（快捷键/托盘/多窗口/通知）"
```

---

## M0 · 任务 6：移动能力 PoC（Android 优先：通知 / 小组件 / 分享接入 / Quick Actions）

**前置：** 所有者已按《docs/开发环境准备清单.md》步骤 A/B 完成 Android SDK 安装与手机接入；`flutter doctor` 的 Android toolchain 为 ✓，`adb devices` 能看到手机。未满足则本任务暂停。

**Files:**
- Create: `apps/seqpoint_app/lib/poc/mobile_poc_page.dart`
- Modify: `apps/seqpoint_app/android/app/src/main/AndroidManifest.xml`
- Create: `apps/seqpoint_app/android/app/src/main/kotlin/com/seqpoint/seqpoint_app/TodayWidgetProvider.kt`
- Create: `apps/seqpoint_app/android/app/src/main/res/layout/today_widget.xml`、`res/xml/today_widget_info.xml`

**Interfaces:**
- Produces: M1 `NotificationService.schedule(id, title, body, at, actions)`、`WidgetService.updateTodayCount(int)`、`ShareIntake.stream`、`QuickActionsService.register()` 的原型；通知动作 id 约定 `done` / `snooze`。

- [ ] **Step 1: 添加依赖**

```bash
cd apps/seqpoint_app && flutter pub add flutter_local_notifications timezone home_widget receive_sharing_intent quick_actions && cd ../..
```

- [ ] **Step 2: AndroidManifest 权限、接收器与分享入口**

在 `<manifest>` 下加：

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.VIBRATE"/>
```

在 `<application>` 下加：

```xml
<receiver android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" android:exported="false"/>
<receiver android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver" android:exported="false">
  <intent-filter>
    <action android:name="android.intent.action.BOOT_COMPLETED"/>
    <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
  </intent-filter>
</receiver>
<receiver android:name=".TodayWidgetProvider" android:exported="true">
  <intent-filter><action android:name="android.appwidget.action.APPWIDGET_UPDATE"/></intent-filter>
  <meta-data android:name="android.appwidget.provider" android:resource="@xml/today_widget_info"/>
</receiver>
```

在 `MainActivity` 的 `<activity>` 内追加分享接入：

```xml
<intent-filter>
  <action android:name="android.intent.action.SEND"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <data android:mimeType="text/plain"/>
</intent-filter>
```

- [ ] **Step 3: 小组件原生部分**

```kotlin
// android/app/src/main/kotlin/com/seqpoint/seqpoint_app/TodayWidgetProvider.kt
package com.seqpoint.seqpoint_app

import android.appwidget.AppWidgetManager
import android.content.Context
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

class TodayWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: android.content.SharedPreferences) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.today_widget)
            val count = widgetData.getInt("today_count", 0)
            views.setTextViewText(R.id.today_count, "今日还有 $count 件")
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
```

```xml
<!-- res/layout/today_widget.xml -->
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent" android:layout_height="match_parent"
    android:orientation="vertical" android:padding="12dp" android:background="#F6DC85">
  <TextView android:id="@+id/today_count" android:layout_width="wrap_content" android:layout_height="wrap_content"
      android:text="今日还有 0 件" android:textColor="#3A3012" android:textSize="16sp"/>
</LinearLayout>
```

```xml
<!-- res/xml/today_widget_info.xml -->
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:minWidth="110dp" android:minHeight="40dp" android:updatePeriodMillis="1800000"
    android:initialLayout="@layout/today_widget" android:resizeMode="horizontal|vertical"
    android:widgetCategory="home_screen"/>
```

- [ ] **Step 4: PoC 页面**

```dart
// apps/seqpoint_app/lib/poc/mobile_poc_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:home_widget/home_widget.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class MobilePocPage extends StatefulWidget {
  const MobilePocPage({super.key});
  @override
  State<MobilePocPage> createState() => _MobilePocPageState();
}

class _MobilePocPageState extends State<MobilePocPage> {
  final _plugin = FlutterLocalNotificationsPlugin();
  final _log = <String>[];
  StreamSubscription? _shareSub;
  int _count = 0;

  void _add(String s) => setState(() => _log.insert(0, s));

  @override
  void initState() {
    super.initState();
    tzdata.initializeTimeZones();
    _plugin.initialize(
      const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (r) => _add('通知响应 action=${r.actionId} payload=${r.payload}'),
    );
    _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    const QuickActions().initialize((type) => _add('Quick Action: $type'));
    const QuickActions().setShortcutItems(const [
      ShortcutItem(type: 'quick_note', localizedTitle: '快速记录'),
      ShortcutItem(type: 'voice_note', localizedTitle: '语音速记'),
    ]);
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen((files) {
      for (final f in files) { _add('分享接入：${f.path}'); }
    });
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      for (final f in files) { _add('冷启动分享：${f.path}'); }
      ReceiveSharingIntent.instance.reset();
    });
  }

  Future<void> _scheduleIn10s() async {
    await _plugin.zonedSchedule(
      1, '序点', '"回复张三报价"今天到期，尚未开始',
      tz.TZDateTime.now(tz.local).add(const Duration(seconds: 10)),
      const NotificationDetails(android: AndroidNotificationDetails('reminders', '提醒',
          importance: Importance.high, priority: Priority.high,
          actions: [AndroidNotificationAction('done', '完成'), AndroidNotificationAction('snooze', '稍后 1 小时')])),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: 'item:demo',
    );
    _add('10 秒后提醒已排程');
  }

  Future<void> _bumpWidget() async {
    _count++;
    await HomeWidget.saveWidgetData<int>('today_count', _count);
    await HomeWidget.updateWidget(androidName: 'TodayWidgetProvider');
    _add('小组件计数 → $_count');
  }

  @override
  void dispose() { _shareSub?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('PoC · 移动能力')),
        body: Column(children: [
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: _scheduleIn10s, child: const Text('10 秒后提醒')),
            FilledButton(onPressed: _bumpWidget, child: const Text('更新小组件')),
          ]),
          Expanded(child: ListView(children: [for (final l in _log) ListTile(dense: true, title: Text(l))])),
        ]),
      );
}
```

- [ ] **Step 5: 真机验证**

```bash
cd apps/seqpoint_app && flutter run -d <adb devices 里的设备 id>
```

验收清单（记录到 `docs/decisions/0003-mobile-poc.md`）：① 点"10 秒后提醒"，锁屏状态下 10 秒内收到通知，点"完成"按钮日志出现 `action=done`；② 桌面添加"序点"小组件，点"更新小组件"后数字变化；③ 在浏览器选一段文字分享到序点，日志出现分享内容；④ 长按 App 图标出现"快速记录 / 语音速记"，点击后日志出现类型。

- [ ] **Step 6: 提交**

```bash
git add -A && git commit -m "feat(app): 移动能力 PoC（通知/小组件/分享/Quick Actions，Android）"
```

---

## M0 · 任务 7：局域网同步 PoC（HLC + Operation Log + 字段级合并 + 加密会话，纯 Dart 可测）

**Files:**
- Create: `packages/seqpoint_core/lib/src/sync/hlc.dart`、`op_log.dart`、`merge.dart`、`crypto_session.dart`、`lan_channel.dart`
- Modify: `packages/seqpoint_core/lib/seqpoint_core.dart`（导出 sync）
- Test: `packages/seqpoint_core/test/sync/hlc_test.dart`、`merge_test.dart`、`crypto_session_test.dart`、`lan_channel_test.dart`
- Create: `apps/seqpoint_app/lib/poc/lan_sync_poc_page.dart`

**Interfaces:**
- Produces（M4 直接沿用）：
  - `class Hlc implements Comparable<Hlc> { final int millis; final int counter; final String deviceId; factory Hlc.now(String deviceId, {Hlc? last}); static Hlc parse(String s); String toString(); }`
  - `class Operation { final String opId; final String deviceId; final Hlc hlc; final String objectType; final String objectId; final String field; final Object? value; Map<String, Object?> toJson(); factory Operation.fromJson(Map); }`
  - `class OpLog { void append(Operation op); List<Operation> since(Map<String,int> peerSummary); Map<String,int> get summary; List<Operation> get all; }`
  - `class FieldMerge { Map<String, Map<String, Object?>> materialize(Iterable<Operation> ops); }`
  - `class CryptoSession { static Future<CryptoSession> handshake(SimpleKeyPair mine, SimplePublicKey theirs); Future<List<int>> seal(Map<String,Object?> msg); Future<Map<String,Object?>> open(List<int> frame); }`
  - `class LanChannel { static Future<LanChannel> listen(int port, SimpleKeyPair kp, OpLog log); static Future<LanChannel> connect(String host, int port, SimpleKeyPair kp, OpLog log); Future<void> syncOnce(); Future<void> close(); }`

- [ ] **Step 1: 添加依赖**

```bash
cd packages/seqpoint_core && dart pub add cryptography uuid && cd ../../apps/seqpoint_app && flutter pub add nsd && cd ../..
```

- [ ] **Step 2: 写失败测试（HLC 与合并）**

```dart
// packages/seqpoint_core/test/sync/hlc_test.dart
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('同一设备连续生成单调递增', () {
    final a = Hlc.now('dev-a');
    final b = Hlc.now('dev-a', last: a);
    expect(b.compareTo(a), greaterThan(0));
  });
  test('物理时间相同则按 counter，再按 deviceId 决胜', () {
    final x = Hlc(millis: 100, counter: 0, deviceId: 'dev-a');
    final y = Hlc(millis: 100, counter: 1, deviceId: 'dev-a');
    final z = Hlc(millis: 100, counter: 1, deviceId: 'dev-b');
    expect(y.compareTo(x), greaterThan(0));
    expect(z.compareTo(y), greaterThan(0));
  });
  test('字符串往返', () {
    final h = Hlc(millis: 1725000000000, counter: 3, deviceId: 'dev-a');
    expect(Hlc.parse(h.toString()), equals(h));
  });
}
```

```dart
// packages/seqpoint_core/test/sync/merge_test.dart
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

Operation op(String dev, int ms, String field, Object? v) => Operation(
      opId: '$dev-$ms-$field', deviceId: dev,
      hlc: Hlc(millis: ms, counter: 0, deviceId: dev),
      objectType: 'item', objectId: 'i1', field: field, value: v);

void main() {
  test('不同字段并发修改都保留', () {
    final ops = [op('phone', 100, 'tags', ['运维']), op('pc', 101, 'due_at', '2026-09-05')];
    final state = FieldMerge().materialize(ops)['i1']!;
    expect(state['tags'], ['运维']);
    expect(state['due_at'], '2026-09-05');
  });
  test('同字段并发按 HLC 高者胜，且与应用顺序无关', () {
    final a = op('phone', 100, 'priority', 'P3');
    final b = op('pc', 100, 'priority', 'P1'); // 同毫秒，deviceId 'pc' > 'phone'
    final s1 = FieldMerge().materialize([a, b])['i1']!['priority'];
    final s2 = FieldMerge().materialize([b, a])['i1']!['priority'];
    expect(s1, 'P1');
    expect(s2, 'P1');
  });
  test('OpLog 摘要与增量：只返回对方缺的操作', () {
    final log = OpLog()..append(op('phone', 1, 'title', 'a'))..append(op('phone', 2, 'title', 'b'))..append(op('pc', 1, 'title', 'c'));
    final missing = log.since({'phone': 1}); // 对方已有 phone 的第 1 条
    expect(missing.map((o) => o.opId), unorderedEquals(['phone-2-title', 'pc-1-title']));
    expect(log.summary, {'phone': 2, 'pc': 1});
  });
}
```

运行：`cd packages/seqpoint_core && dart test test/sync` → 预期 FAIL（类未定义）。

- [ ] **Step 3: 实现 HLC / Operation / OpLog / FieldMerge**

```dart
// packages/seqpoint_core/lib/src/sync/hlc.dart
/// 混合逻辑时钟：millis:counter:deviceId，全序可比较，用于字段级合并决胜。
class Hlc implements Comparable<Hlc> {
  const Hlc({required this.millis, required this.counter, required this.deviceId});
  final int millis;
  final int counter;
  final String deviceId;

  factory Hlc.now(String deviceId, {Hlc? last}) {
    final wall = DateTime.now().millisecondsSinceEpoch;
    if (last == null || wall > last.millis) return Hlc(millis: wall, counter: 0, deviceId: deviceId);
    return Hlc(millis: last.millis, counter: last.counter + 1, deviceId: deviceId);
  }

  static Hlc parse(String s) {
    final p = s.split(':');
    return Hlc(millis: int.parse(p[0]), counter: int.parse(p[1]), deviceId: p.sublist(2).join(':'));
  }

  @override
  int compareTo(Hlc o) {
    if (millis != o.millis) return millis.compareTo(o.millis);
    if (counter != o.counter) return counter.compareTo(o.counter);
    return deviceId.compareTo(o.deviceId);
  }

  @override
  String toString() => '$millis:$counter:$deviceId';
  @override
  bool operator ==(Object o) => o is Hlc && compareTo(o) == 0;
  @override
  int get hashCode => Object.hash(millis, counter, deviceId);
}
```

```dart
// packages/seqpoint_core/lib/src/sync/op_log.dart
import 'hlc.dart';

/// 一次字段写入。M4 的正式版本会在此基础上加签名与密文，字段名不变。
class Operation {
  const Operation({required this.opId, required this.deviceId, required this.hlc, required this.objectType,
      required this.objectId, required this.field, required this.value});
  final String opId, deviceId, objectType, objectId, field;
  final Hlc hlc;
  final Object? value;

  Map<String, Object?> toJson() => {'op_id': opId, 'device_id': deviceId, 'hlc': hlc.toString(),
      'object_type': objectType, 'object_id': objectId, 'field': field, 'value': value};

  factory Operation.fromJson(Map<String, Object?> j) => Operation(
      opId: j['op_id'] as String, deviceId: j['device_id'] as String, hlc: Hlc.parse(j['hlc'] as String),
      objectType: j['object_type'] as String, objectId: j['object_id'] as String, field: j['field'] as String,
      value: j['value']);
}

/// 按设备维护序号的操作日志；`summary` 是 {deviceId: 已知最大序号}，用于增量交换。
class OpLog {
  final List<Operation> _ops = [];
  final Map<String, List<Operation>> _byDevice = {};
  final Set<String> _ids = {};

  List<Operation> get all => List.unmodifiable(_ops);
  Map<String, int> get summary => {for (final e in _byDevice.entries) e.key: e.value.length};

  /// 幂等：同 opId 只记一次（SYNC-006）。
  void append(Operation op) {
    if (!_ids.add(op.opId)) return;
    _ops.add(op);
    _byDevice.putIfAbsent(op.deviceId, () => []).add(op);
  }

  List<Operation> since(Map<String, int> peer) => [
        for (final e in _byDevice.entries) ...e.value.skip(peer[e.key] ?? 0),
      ];
}
```

```dart
// packages/seqpoint_core/lib/src/sync/merge.dart
import 'op_log.dart';

/// 字段级 LWW：每个 objectId 的每个 field 取 HLC 最大的值，结果与输入顺序无关（SYNC-002/003）。
class FieldMerge {
  Map<String, Map<String, Object?>> materialize(Iterable<Operation> ops) {
    final winners = <String, Map<String, Operation>>{};
    for (final op in ops) {
      final fields = winners.putIfAbsent(op.objectId, () => {});
      final cur = fields[op.field];
      if (cur == null || op.hlc.compareTo(cur.hlc) > 0) fields[op.field] = op;
    }
    return {for (final e in winners.entries) e.key: {for (final f in e.value.entries) f.key: f.value.value}};
  }
}
```

运行：`dart test test/sync` → 预期 hlc_test 与 merge_test 全部 PASS。提交：`git add -A && git commit -m "feat(core): HLC、OpLog 与字段级合并"`。

- [ ] **Step 4: 加密会话（失败测试 → 实现）**

```dart
// packages/seqpoint_core/test/sync/crypto_session_test.dart
import 'package:cryptography/cryptography.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('双方派生相同会话密钥，密文可解，篡改后失败', () async {
    final x = X25519();
    final a = await x.newKeyPair();
    final b = await x.newKeyPair();
    final sa = await CryptoSession.handshake(a, await b.extractPublicKey());
    final sb = await CryptoSession.handshake(b, await a.extractPublicKey());
    final frame = await sa.seal({'hello': '序点'});
    expect(await sb.open(frame), {'hello': '序点'});
    final tampered = List<int>.from(frame)..[frame.length - 1] ^= 0x01;
    expect(() => sb.open(tampered), throwsA(isA<SecretBoxAuthenticationError>()));
  });
}
```

```dart
// packages/seqpoint_core/lib/src/sync/crypto_session.dart
import 'dart:convert';
import 'package:cryptography/cryptography.dart';

/// X25519 协商 → HKDF 派生 → XChaCha20-Poly1305 加密每条消息（应用层 E2EE，PRD V1.1 §11.5 第 4 条）。
class CryptoSession {
  CryptoSession._(this._key);
  final SecretKey _key;
  static final _aead = Xchacha20.poly1305Aead();

  static Future<CryptoSession> handshake(SimpleKeyPair mine, SimplePublicKey theirs) async {
    final shared = await X25519().sharedSecretKey(keyPair: mine, remotePublicKey: theirs);
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: shared, info: utf8.encode('seqpoint-lan-poc-v1'));
    return CryptoSession._(key);
  }

  /// 帧格式：24 字节 nonce + 密文 + 16 字节 MAC。
  Future<List<int>> seal(Map<String, Object?> msg) async {
    final box = await _aead.encrypt(utf8.encode(jsonEncode(msg)), secretKey: _key);
    return [...box.nonce, ...box.cipherText, ...box.mac.bytes];
  }

  Future<Map<String, Object?>> open(List<int> frame) async {
    final box = SecretBox(frame.sublist(24, frame.length - 16), nonce: frame.sublist(0, 24), mac: Mac(frame.sublist(frame.length - 16)));
    final clear = await _aead.decrypt(box, secretKey: _key);
    return jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
  }
}
```

运行：`dart test test/sync/crypto_session_test.dart` → PASS。提交：`git commit -am "feat(core): X25519 + XChaCha20-Poly1305 会话"`。

- [ ] **Step 5: 直连通道（localhost 测试 → 实现）**

```dart
// packages/seqpoint_core/test/sync/lan_channel_test.dart
import 'package:cryptography/cryptography.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('两端各自写入后一次同步即收敛', () async {
    final kpA = await X25519().newKeyPair(), kpB = await X25519().newKeyPair();
    final logA = OpLog()..append(Operation(opId: 'a1', deviceId: 'A', hlc: Hlc(millis: 1, counter: 0, deviceId: 'A'), objectType: 'note', objectId: 'n1', field: 'raw_content', value: '手机记的'));
    final logB = OpLog()..append(Operation(opId: 'b1', deviceId: 'B', hlc: Hlc(millis: 2, counter: 0, deviceId: 'B'), objectType: 'note', objectId: 'n1', field: 'title', value: '电脑起的标题'));
    final server = await LanChannel.listen(0, kpA, logA);
    final client = await LanChannel.connect('127.0.0.1', server.port, kpB, logB);
    await client.syncOnce();
    expect(logA.summary, {'A': 1, 'B': 1});
    expect(logB.summary, {'A': 1, 'B': 1});
    final stateA = FieldMerge().materialize(logA.all)['n1'];
    expect(stateA, {'raw_content': '手机记的', 'title': '电脑起的标题'});
    await client.close();
    await server.close();
  });
}
```

```dart
// packages/seqpoint_core/lib/src/sync/lan_channel.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'crypto_session.dart';
import 'op_log.dart';

/// TCP 直连：明文交换 X25519 公钥（M4 改为 QR 配对预共享的互信公钥 + 签名），之后所有帧走 CryptoSession。
/// 帧 = 4 字节大端长度 + 载荷。
class LanChannel {
  LanChannel._(this._socket, this._log, this._kp, {this.port = 0, ServerSocket? server}) : _server = server;
  final Socket? _socket;
  final ServerSocket? _server;
  final OpLog _log;
  final SimpleKeyPair _kp;
  final int port;
  CryptoSession? _session;
  final _inbox = StreamController<List<int>>();

  static Future<LanChannel> listen(int port, SimpleKeyPair kp, OpLog log) async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    final ch = LanChannel._(null, log, kp, port: server.port, server: server);
    server.listen((socket) async {
      final peer = LanChannel._(socket, log, kp);
      peer._pump();
      await peer._handshake();
      await peer._serve();
    });
    return ch;
  }

  static Future<LanChannel> connect(String host, int port, SimpleKeyPair kp, OpLog log) async {
    final ch = LanChannel._(await Socket.connect(host, port), log, kp);
    ch._pump();
    await ch._handshake();
    return ch;
  }

  void _pump() {
    final buf = BytesBuilder();
    _socket!.listen((chunk) {
      buf.add(chunk);
      while (true) {
        final bytes = buf.toBytes();
        if (bytes.length < 4) return;
        final len = ByteData.sublistView(bytes, 0, 4).getUint32(0);
        if (bytes.length < 4 + len) return;
        _inbox.add(bytes.sublist(4, 4 + len));
        buf.clear();
        buf.add(bytes.sublist(4 + len));
      }
    }, onDone: _inbox.close);
  }

  Future<void> _sendRaw(List<int> payload) async {
    final len = ByteData(4)..setUint32(0, payload.length);
    _socket!.add([...len.buffer.asUint8List(), ...payload]);
    await _socket!.flush();
  }

  late final StreamIterator<List<int>> _it = StreamIterator(_inbox.stream);
  Future<List<int>> _recvRaw() async { await _it.moveNext(); return _it.current; }

  Future<void> _handshake() async {
    final pub = await _kp.extractPublicKey();
    await _sendRaw(pub.bytes);
    final theirs = SimplePublicKey(await _recvRaw(), type: KeyPairType.x25519);
    _session = await CryptoSession.handshake(_kp, theirs);
  }

  Future<void> _send(Map<String, Object?> m) async => _sendRaw(await _session!.seal(m));
  Future<Map<String, Object?>> _recv() async => _session!.open(await _recvRaw());

  /// 客户端：发我的摘要 → 收对方缺失清单 → 发对方缺的 → 收我缺的。
  Future<void> syncOnce() async {
    await _send({'type': 'summary', 'summary': _log.summary});
    final theirSummary = (await _recv())['summary'] as Map<String, Object?>;
    await _send({'type': 'ops', 'ops': _log.since(theirSummary.cast<String, int>()).map((o) => o.toJson()).toList()});
    for (final j in ((await _recv())['ops'] as List)) {
      _log.append(Operation.fromJson((j as Map).cast<String, Object?>()));
    }
  }

  /// 服务端：对称流程。
  Future<void> _serve() async {
    final theirSummary = (await _recv())['summary'] as Map<String, Object?>;
    await _send({'type': 'summary', 'summary': _log.summary});
    for (final j in ((await _recv())['ops'] as List)) {
      _log.append(Operation.fromJson((j as Map).cast<String, Object?>()));
    }
    await _send({'type': 'ops', 'ops': _log.since(theirSummary.cast<String, int>()).map((o) => o.toJson()).toList()});
  }

  Future<void> close() async { await _socket?.close(); await _server?.close(); }
}
```

在 `lib/seqpoint_core.dart` 追加 `export 'src/sync/hlc.dart'; export 'src/sync/op_log.dart'; export 'src/sync/merge.dart'; export 'src/sync/crypto_session.dart'; export 'src/sync/lan_channel.dart';`。

运行：`dart test test/sync` → 全部 PASS。提交：`git commit -am "feat(core): 局域网直连通道与一次同步"`。

- [ ] **Step 6: App 内跨设备验证（nsd 发现）**

```dart
// apps/seqpoint_app/lib/poc/lan_sync_poc_page.dart（要点）
// 1. 启动时 LanChannel.listen(0, kp, log)，用 nsd 的 register(Service(name: 'SeqPoint-<设备名>', type: '_seqpoint._tcp', port: port)) 广播；
// 2. 用 nsd 的 startDiscovery('_seqpoint._tcp') 列出其他设备，点击某台 → LanChannel.connect(host, port, kp, log) → syncOnce()；
// 3. 页面上有"写一条便签操作"按钮（append 一个 Operation），以及显示 FieldMerge().materialize(log.all) 的结果表。
```

验收：Mac 与 Android 手机同一 Wi-Fi，各自写入不同字段，任一端点"同步"后两端结果表一致；抓包（Wireshark 过滤 tcp.port）只见握手公钥与密文。记录到 `docs/decisions/0004-lan-sync-poc.md`。macOS 需要在 entitlements 加 `com.apple.security.network.server` 与 `com.apple.security.network.client`；Android 需要 `INTERNET` 权限（默认已有）。

- [ ] **Step 7: 提交**

```bash
git add -A && git commit -m "feat(app): 局域网同步 PoC 页面（nsd 发现 + 直连）"
```

---

## M0 · 任务 8：设计令牌与主题基线

**Files:**
- Create: `apps/seqpoint_app/lib/theme/seq_tokens.dart`、`apps/seqpoint_app/lib/theme/seq_theme.dart`
- Create: `docs/design/关键页面清单.md`
- Test: `apps/seqpoint_app/test/theme_test.dart`

**Interfaces:**
- Produces: `class SeqTokens { static const paper, ink, inkMuted, line, accent, accentInk, noteYellow, noteInk; static const darkBg, darkInk, darkAccent; }`、`ThemeData seqLightTheme()`、`ThemeData seqDarkTheme()`；M1 所有界面只从这里取色。

- [ ] **Step 1: 写失败测试**

```dart
// apps/seqpoint_app/test/theme_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/theme/seq_theme.dart';
import 'package:seqpoint_app/theme/seq_tokens.dart';

void main() {
  test('浅色主题使用纸白底与琥珀重点色', () {
    final t = seqLightTheme();
    expect(t.scaffoldBackgroundColor, SeqTokens.paper);
    expect(t.colorScheme.primary, SeqTokens.accentInk);
  });
  test('深色主题底色为暖黑', () {
    expect(seqDarkTheme().scaffoldBackgroundColor, SeqTokens.darkBg);
  });
  testWidgets('便签色块在两种主题下都是同一张纸', (tester) async {
    expect(SeqTokens.noteYellow, const Color(0xFFF6DC85));
  });
}
```

运行：`cd apps/seqpoint_app && flutter test test/theme_test.dart` → FAIL（文件不存在）。

- [ ] **Step 2: 实现令牌与主题（数值来自设计 V2.x 在线版）**

```dart
// apps/seqpoint_app/lib/theme/seq_tokens.dart
import 'package:flutter/material.dart';

/// 设计令牌：暖纸白 + 琥珀便签色；便签纸在明暗主题下保持同色（"纸就是纸"）。
abstract final class SeqTokens {
  static const paper = Color(0xFFFAF8F3);
  static const ink = Color(0xFF262219);
  static const inkMuted = Color(0xFF6E675A);
  static const line = Color(0xFFE7E1D2);
  static const accent = Color(0xFFF1C232);
  static const accentInk = Color(0xFF8A6B14);
  static const noteYellow = Color(0xFFF6DC85);
  static const noteInk = Color(0xFF3A3012);
  static const darkBg = Color(0xFF1B1915);
  static const darkInk = Color(0xFFECE7DB);
  static const darkAccent = Color(0xFFE5BE44);
}
```

```dart
// apps/seqpoint_app/lib/theme/seq_theme.dart
import 'package:flutter/material.dart';
import 'seq_tokens.dart';

ThemeData seqLightTheme() => ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: SeqTokens.paper,
      colorScheme: ColorScheme.fromSeed(seedColor: SeqTokens.accent, brightness: Brightness.light)
          .copyWith(primary: SeqTokens.accentInk, surface: SeqTokens.paper, onSurface: SeqTokens.ink),
      fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei', 'Noto Sans SC'],
    );

ThemeData seqDarkTheme() => ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: SeqTokens.darkBg,
      colorScheme: ColorScheme.fromSeed(seedColor: SeqTokens.darkAccent, brightness: Brightness.dark)
          .copyWith(primary: SeqTokens.darkAccent, surface: SeqTokens.darkBg, onSurface: SeqTokens.darkInk),
      fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei', 'Noto Sans SC'],
    );
```

运行：`flutter test test/theme_test.dart` → PASS。

- [ ] **Step 3: 写关键页面清单（设计稿的验收依据）**

`docs/design/关键页面清单.md` 必须逐页列出：桌面便签窗（空 / 有文字 / 行悬停出现○ / 事项行 / 全部完成提示关闭 / 揭走动画）、桌面主面板（今日 / 便签墙 / 全部事项 / 标签 / 已归档 / 回收站 / 设置）、移动 今日 / 便签 / ＋ 面板 / 我的、AI 确认卡（逐条改 / 全部采纳 / 撤销）、同步状态条（仅本机 / 已同步到 × 台 / 待中转）。每页写清状态、进入方式、主要动作与空态文案；高保真稿由所有者在此清单基础上完成。

- [ ] **Step 4: 提交**

```bash
git add -A && git commit -m "feat(app): 设计令牌与主题；docs: 关键页面清单"
```

---

## M0 · 任务 9：选中即整理可行性 PoC（macOS Swift + Windows C++ 方法通道）

**Files:**
- Create: `apps/seqpoint_app/lib/platform/selected_text_service.dart`
- Create: `apps/seqpoint_app/macos/Runner/SelectedTextPlugin.swift`；Modify: `macos/Runner/MainFlutterWindow.swift`
- Create: `apps/seqpoint_app/windows/runner/selected_text_plugin.cpp`、`.h`；Modify: `windows/runner/flutter_window.cpp`、`CMakeLists.txt`
- Modify: `apps/seqpoint_app/lib/poc/desktop_poc_page.dart`（加 `⌥⇧T` 与按钮）

**Interfaces:**
- Produces: `class SelectedTextService { static const channel = MethodChannel('seqpoint/selected_text'); Future<String?> getSelectedText(); }`；M2 的 T2.8 直接调用。

- [ ] **Step 1: Dart 侧**

```dart
// apps/seqpoint_app/lib/platform/selected_text_service.dart
import 'package:flutter/services.dart';

/// 读取当前前台应用的选中文字：macOS 通过辅助功能发送 ⌘C 并还原剪贴板；Windows 通过 SendInput Ctrl+C。
class SelectedTextService {
  static const _channel = MethodChannel('seqpoint/selected_text');
  Future<String?> getSelectedText() async =>
      await _channel.invokeMethod<String>('getSelectedText');
}
```

- [ ] **Step 2: macOS 原生**

```swift
// apps/seqpoint_app/macos/Runner/SelectedTextPlugin.swift
import Cocoa
import FlutterMacOS

final class SelectedTextPlugin {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "seqpoint/selected_text", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "getSelectedText" else { result(FlutterMethodNotImplemented); return }
      let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      guard AXIsProcessTrustedWithOptions(opts) else {
        result(FlutterError(code: "no_accessibility", message: "需要在系统设置→隐私与安全性→辅助功能中允许序点", details: nil)); return
      }
      let pb = NSPasteboard.general
      let oldItems = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
        let copy = NSPasteboardItem()
        for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
        return copy
      } ?? []
      let oldCount = pb.changeCount
      let src = CGEventSource(stateID: .combinedSessionState)
      let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)  // 'c'
      let up = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
      down?.flags = .maskCommand; up?.flags = .maskCommand
      down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        let text = pb.changeCount != oldCount ? pb.string(forType: .string) : nil
        pb.clearContents(); if !oldItems.isEmpty { pb.writeObjects(oldItems) }
        result(text)
      }
    }
  }
}
```

在 `MainFlutterWindow.swift` 的 `RegisterGeneratedPlugins(registry: flutterViewController)` 之后加一行：`SelectedTextPlugin.register(with: flutterViewController.engine.binaryMessenger)`。

- [ ] **Step 3: Windows 原生**

```cpp
// apps/seqpoint_app/windows/runner/selected_text_plugin.cpp
#include "selected_text_plugin.h"
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <string>

static std::wstring ReadClipboardText() {
  std::wstring out;
  if (!OpenClipboard(nullptr)) return out;
  if (HANDLE h = GetClipboardData(CF_UNICODETEXT)) {
    if (auto* p = static_cast<wchar_t*>(GlobalLock(h))) { out = p; GlobalUnlock(h); }
  }
  CloseClipboard();
  return out;
}

static void WriteClipboardText(const std::wstring& s) {
  if (!OpenClipboard(nullptr)) return;
  EmptyClipboard();
  HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, (s.size() + 1) * sizeof(wchar_t));
  if (h) { memcpy(GlobalLock(h), s.c_str(), (s.size() + 1) * sizeof(wchar_t)); GlobalUnlock(h); SetClipboardData(CF_UNICODETEXT, h); }
  CloseClipboard();
}

static void SendCtrlC() {
  INPUT in[4] = {};
  in[0].type = in[1].type = in[2].type = in[3].type = INPUT_KEYBOARD;
  in[0].ki.wVk = VK_CONTROL; in[1].ki.wVk = 'C';
  in[2].ki.wVk = 'C'; in[2].ki.dwFlags = KEYEVENTF_KEYUP;
  in[3].ki.wVk = VK_CONTROL; in[3].ki.dwFlags = KEYEVENTF_KEYUP;
  SendInput(4, in, sizeof(INPUT));
}

void RegisterSelectedTextPlugin(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "seqpoint/selected_text", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "getSelectedText") { result->NotImplemented(); return; }
    const std::wstring old = ReadClipboardText();
    SendCtrlC();
    Sleep(150);
    const std::wstring text = ReadClipboardText();
    WriteClipboardText(old);
    if (text.empty() || text == old) { result->Success(); return; }
    const int n = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string utf8(n, 0); WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, utf8.data(), n, nullptr, nullptr);
    utf8.resize(n - 1);
    result->Success(flutter::EncodableValue(utf8));
  });
  channel.release();
}
```

`selected_text_plugin.h` 声明 `void RegisterSelectedTextPlugin(flutter::BinaryMessenger*);`；在 `flutter_window.cpp` 的 `RegisterPlugins(flutter_controller_->engine());` 后调用 `RegisterSelectedTextPlugin(flutter_controller_->engine()->messenger());`；`CMakeLists.txt` 的 runner 源文件列表加入 `selected_text_plugin.cpp`。

- [ ] **Step 4: 接到 PoC 页面并验证**

在 `desktop_poc_page.dart` 注册第二个系统级快捷键 `HotKey(key: PhysicalKeyboardKey.keyT, modifiers: [HotKeyModifier.alt, HotKeyModifier.shift], scope: HotKeyScope.system)`，回调里 `final t = await SelectedTextService().getSelectedText(); _add('选中文字：${t ?? "(无)"}');`。

验收：在 Safari / Chrome / 微信里选中一段文字，按 `⌥⇧T`（Windows `Alt+Shift+T`），日志显示该文字；随后 `⌘V` 粘贴到任意输入框，得到的仍是**之前**剪贴板的内容（还原成功）；未授权辅助功能时给出明确提示。结论写入 `docs/decisions/0005-selected-text-poc.md`，失败时的退化方案为"⌥⇧V 剪贴板成便签"。

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "feat(app): 选中即整理可行性 PoC（macOS/Windows 方法通道）"
```

---

## M0 · 任务 10：CI 与密钥扫描

**Files:**
- Create: `scripts/scan_secrets.sh`、`scripts/ci_local.sh`、`.github/workflows/ci.yml`、`docs/日志脱敏规范.md`

**Interfaces:**
- Produces: `scripts/scan_secrets.sh` 退出码 0/1；CI 在 push 与 PR 上运行 analyze / test / 四端构建。

- [ ] **Step 1: 密钥扫描脚本（先用假密钥验证它会失败）**

```bash
# scripts/scan_secrets.sh
#!/usr/bin/env bash
# 扫描仓库中的密钥模式；命中则退出 1（NFR-113）。
set -euo pipefail
cd "$(dirname "$0")/.."
PATTERN='sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA|EC|OPENSSH) PRIVATE KEY-----'
if grep -rInE --exclude-dir={.git,build,.dart_tool,ephemeral,Pods} --exclude='*.lock' --exclude='scan_secrets.sh' "$PATTERN" . ; then
  echo "✗ 发现疑似密钥，禁止提交" >&2; exit 1
fi
echo "✓ 未发现密钥模式"
```

```bash
chmod +x scripts/scan_secrets.sh
echo 'const k = "sk-ant-api03-FAKEFAKEFAKEFAKEFAKEFAKE";' > /tmp/leak_test.dart && cp /tmp/leak_test.dart apps/seqpoint_app/lib/leak_test.dart
scripts/scan_secrets.sh; echo "exit=$?"     # 预期 exit=1
rm apps/seqpoint_app/lib/leak_test.dart
scripts/scan_secrets.sh                      # 预期 ✓ 未发现密钥模式
```

PowerShell 等价：`git ls-files | Select-String -Pattern 'sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}'`。

- [ ] **Step 2: 本地 CI 脚本与 GitHub Actions**

```bash
# scripts/ci_local.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/scan_secrets.sh
dart pub get
(cd packages/seqpoint_core && dart analyze && dart test)
(cd apps/seqpoint_app && flutter analyze && flutter test)
```

```yaml
# .github/workflows/ci.yml
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { flutter-version: '3.44.0', channel: stable }
      - run: scripts/scan_secrets.sh
      - run: dart pub get
      - run: cd packages/seqpoint_core && dart analyze && dart test
      - run: cd apps/seqpoint_app && flutter analyze && flutter test
      - run: cd apps/seqpoint_app && flutter build macos --debug && flutter build ios --debug --no-codesign && flutter build apk --debug
  windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { flutter-version: '3.44.0', channel: stable }
      - run: dart pub get
      - run: cd apps/seqpoint_app; flutter build windows --debug
```

- [ ] **Step 3: 日志脱敏规范**

`docs/日志脱敏规范.md` 三条硬规则：① 日志只记 id、长度、状态与耗时，永不记 `raw_content`、标题、标签名、转写；② 密钥类只记"已配置/未配置"；③ 崩溃上报（M5）默认关，开启时同样过滤。附一段示例：`log.info('note.saved id=$id len=${raw.length}')`。

- [ ] **Step 4: 提交**

```bash
git add -A && git commit -m "chore: 密钥扫描、本地 CI 脚本与 GitHub Actions；docs: 日志脱敏规范"
```

---

## M0 决策门

| 必须通过 | 证据文件 | 通过标准 |
|---|---|---|
| 任务 1 骨架 | 仓库 | `scripts/ci_local.sh` 全绿 |
| 任务 3 数据库 | `test/db` | 3 用例 PASS |
| 任务 4 安全存储 | `docs/decisions/0002…` 附截图 | macOS 与 Android 重启后可读，容器扫描无明文 |
| 任务 5 桌面能力 | `docs/decisions/0002-desktop-poc.md` | macOS 五项 ✓，Windows 五项 ✓（快捷键冲突已定案） |
| 任务 6 移动能力 | `docs/decisions/0003-mobile-poc.md` | Android 四项 ✓ |
| 任务 7 局域网同步 | `test/sync` + `0004-lan-sync-poc.md` | 单测全绿；Mac↔Android 收敛；抓包只见密文 |
| 任务 9 选中即整理 | `0005-selected-text-poc.md` | 至少 macOS 通过；Windows 失败则退化方案定案 |

任一项失败：先修方案（换包 / 调整设计），不带着未验证的假设进入 M1。全部通过后删除 `lib/poc/` 前先把可复用代码迁到 `packages/seqpoint_platform`（M1 任务 T1.5–T1.6、T1.12）。

---

# M1 · 双端随手记闭环（任务级分解）

> M1 在 M0 决策门通过后另起一份步骤级计划（`docs/superpowers/plans/<日期>-seqpoint-m1-…md`）。下表锁定每个任务的文件、接口与验收，供该计划直接展开。所有任务都以 `packages/seqpoint_core` 单测先行，界面层只做薄封装。

| 任务 | 文件（Create / Modify） | 接口（Produces） | 验收 | 依赖 |
|---|---|---|---|---|
| T1.1 数据模型与仓储 | `core/lib/src/model/{note,item,tag,reminder,activity}.dart`；`core/lib/src/repo/{note_repository,item_repository,tag_repository,activity_repository}.dart`；`test/repo/*` | `class Note({id, kind, title, rawContent, status, color, pinned, window, createdAt, updatedAt, closedAt, deletedAt, hlc})`；`NoteRepository { Future<Note> insert(Note); Future<Note?> byId(String); Future<List<Note>> active(); Future<void> update(Note); }`；`ItemRepository { Future<Item> insert(Item); Future<List<Item>> byNote(String noteId); Future<List<Item>> dueOn(DateTime day); Future<void> update(Item); }`；`ActivityRepository.log(objectType, objectId, action, {old, new})` | 仓储单测覆盖增删改查与软删除；`updated_at` 自动刷新 | 任务 3 |
| T1.2 便签⇄事项状态机 | `core/lib/src/service/note_service.dart`；`test/service/note_service_test.dart` | `NoteService { Future<Note> capture(String rawText); Future<Item> lineToItem(String noteId, int lineIndex); Future<void> toggleItem(String itemId); Future<bool> closeIfAllDone(String noteId); Future<void> close(String noteId); Future<void> reopen(String noteId); Future<void> trash(String noteId); Future<int> purgeTrash({Duration olderThan = const Duration(days: 30)}); }` | 属性测试：任意勾选序列后 `closeIfAllDone` 当且仅当全部 done 返回 true；纯文字便签不可自动关闭；每次状态变化产生一条 Activity | T1.1 |
| T1.3 本地搜索 | `core/lib/src/db/migrations.dart`（v2：FTS5 表 `search_index(object_type, object_id, text)` + 触发器）；`core/lib/src/search/search_service.dart`；`test/search/*` | `SearchService { Future<List<SearchHit>> query(String q, {bool includeArchived = true}); }`；`SearchHit({objectType, objectId, snippet})` | 中文分词用 FTS5 `trigram`；断网可搜；归档可搜 | T1.1 |
| T1.4 快照与导出 | `core/lib/src/backup/snapshot_service.dart`、`core/lib/src/export/{markdown_exporter,json_exporter}.dart`；`test/backup/*` | `SnapshotService { Future<File> createDaily(Directory dir, {int keep = 7}); Future<void> restore(File snapshot); }`（`VACUUM INTO`）；`MarkdownExporter.export(Directory)`、`JsonExporter.export(File)` | 连续 8 天快照只保留 7 份；恢复后数据一致；导出文件可读 | T1.1 |
| T1.5 托盘与开机自启 | `packages/seqpoint_platform/lib/src/tray_service.dart`、`autostart_service.dart`（`launch_at_startup`） | `TrayService { Future<void> init({required VoidCallback onOpen, required VoidCallback onQuit}); Future<void> setBadge(int count); }` | 关主窗不退出；托盘菜单可开主面板；自启可在设置关闭 | 任务 5 |
| T1.6 全局快捷键 | `platform/lib/src/hotkey_service.dart`；`app/lib/settings/hotkey_settings_page.dart` | `HotkeyService { Future<void> bind(HotkeyAction action, HotKey key); Stream<HotkeyAction> get actions; Future<List<HotkeyConflict>> detectConflicts(); }`；`enum HotkeyAction { toggleQuickNote, newNote, clipboardToNote, organizeSelection, openSearch }` | 默认 `⌥Space / ⌥⇧N / ⌥⇧V / ⌥⇧T / ⌥⇧S`（Windows 用 Alt）；唤起 ≤300ms；可自定义、冲突提示 | 任务 5、任务 9 |
| T1.7 桌面便签窗 | `app/lib/desktop/sticky/{sticky_window,note_editor,item_row,close_animation}.dart`；`platform/lib/src/window_service.dart` | `WindowService { Future<int> openSticky(String noteId); Future<void> saveFrame(String noteId, Rect frame); }`；`NoteEditor(noteId)` 内部使用 `NoteService` | 多开 / 置顶 / 位置记忆 / 底色；行悬停○转事项；勾选划线动效；全部完成提示关闭；"揭走"动画 ≤400ms | T1.2、T1.5 |
| T1.8 桌面主面板 | `app/lib/desktop/panel/{main_panel,today_view,note_wall_view,items_view,tags_view,archive_view,trash_view,settings_view}.dart` | 左导航 + 内容区两栏；`TodayView` 基础版（今天到期 + 逾期 + 今日完成，AI 建议区留空位） | 可导航全部对象；`⌘K` 聚焦搜索 | T1.3、T1.7 |
| T1.9 便签内快捷键 | `app/lib/desktop/sticky/sticky_shortcuts.dart`（Flutter `Shortcuts`/`Actions`） | `⌘Enter` 转事项⇄勾选、`⌘D` 完成、`⌘P` 置顶、`⌘W` 关闭、`⌘K` 搜索、`⌘Z` 撤销、`Esc` 收起（`⌘J` 与 `⌘⇧Enter` 留给 M2） | 核心路径全键盘可完成（NFR-107） | T1.7 |
| T1.10 移动导航与快速记录 | `app/lib/mobile/{mobile_shell,quick_capture_page}.dart` | 底部 今日 · 便签 · ＋ · 我的；＋ 弹出 快速记录 / 语音速记（M2 前灰显）；`QuickCapturePage` 打开即聚焦输入 | 冷启动 ≤2s；输入到保存 3 步内、3 秒内 | T1.2 |
| T1.11 移动便签墙 / 事项 / 详情 | `app/lib/mobile/{note_wall_page,items_page,item_detail_page,note_detail_page}.dart` | 便签 Tab 内 便签墙 / 全部事项 切换；详情可勾选、改截止、关闭便签 | 与桌面数据语义一致（同一 `NoteService`） | T1.10 |
| T1.12 移动快捷入口 | `platform/lib/src/{widget_service,share_intake,quick_actions_service,notification_service}.dart`；Android 小组件（迁自任务 6）；iOS `WidgetKit` 扩展（`ios/TodayWidget/`） | `WidgetService.updateTodayCount(int)`；`ShareIntake.stream → String`（进 `NoteService.capture`）；`QuickActionsService.register()`；通知动作 `done` / `snooze` 回调接口先定义，M3 实现 | 小组件 3 步内保存；分享成便签；长按图标两项动作 | 任务 6、T1.10 |
| T1.13 图片进便签 | `core/lib/src/model/attachment.dart`（migrations v3：`attachments` 表）；`core/lib/src/service/attachment_service.dart`；`app/lib/shared/image_picker_bridge.dart`（移动 `image_picker`，桌面 `pasteboard` 粘贴） | `AttachmentService { Future<Attachment> addImage(String noteId, Uint8List bytes, {String? name}); Future<File> thumbnail(String attachmentId); }`；文件存数据目录 `attachments/<id>` | 缩略图 ≤200px；原图仅本机（同步策略 M4） | T1.1 |

**M1 出口验收：** 飞行模式下，Android 与 macOS 各自：唤起 / 打开快速记录 → 输入三行 → 行转事项 → 勾完 → 便签提示关闭 → 归档可搜 → 重启数据在 → 导出文件可读。所有 `lib/poc/` 删除。

---

# M2–M5 里程碑级（本计划只定目标、依赖与关键技术点）

| 里程碑 | 目标 | 关键技术点 | 依赖 | 出口 |
|---|---|---|---|---|
| **M2 AI 整理与 BYOK** | 整理管线 + 确认卡 + 双维标签 + 密钥安全存储 + 选中即整理 + 语音速记（视转写栈） | 本地规则解析器（中文相对时间、`#`、`!P`）；`AiProvider` 抽象（Claude API / OpenAI 兼容 / 自定义 Base URL），结构化 JSON 输出 schema；`SecretStore`（任务 4 原型）；确认卡为 `core` 中的 `OrganizeProposal` 纯数据 + 界面渲染；AI 评测集 50 条放 `test/fixtures/` 进 CI | M1 | 自用样本采纳率 ≥60%；AI 关闭全流程可用；`scan_secrets.sh` 与容器扫描零命中 |
| **M3 智能提醒与今日** | 五类提醒引擎 + 本地通知调度 + 今日完整版 + 降频 / 汇总 / 稍后 | `ReminderEngine` 纯 Dart（规则可单测：≤2 次/日、30 分钟去重、勿扰、晚间汇总 20:00）；`flutter_local_notifications` 动作按钮回调（任务 6 原型）；跨端去重先做本地语义 | M1、M2（时间解析） | 精确提醒误差 ≤1 分钟；智能提醒受控；晚间汇总 |
| **M4 同步、云中转与备份** | 设备身份 + QR 配对 + Operation Log（签名 + 密文）+ 局域网直连 + 云中转（Mailbox / TTL / ACK 即删）+ 官方与自托管同源节点 + 四层备份 + 设备撤销 + Secret 同步 | 任务 7 的 `Hlc / OpLog / FieldMerge / CryptoSession / LanChannel` 演进为正式模块并加 Ed25519 签名；`node/`（Dart `shelf` 或 Go）实现 Mailbox HTTP API：`POST /mailbox/{id}/ops`、`GET /mailbox/{id}/ops?since=`、`POST /ack`、TTL 清理任务；`SyncProfile` 设置页与口径文案；`VaultBackup` 加密文件格式（Recovery Key 解封） | M1（数据）、M3（提醒状态同步） | AC-003 / AC-005 / AC-007 / AC-008；手机 9 点建、电脑 12 点单独上线经中转收到；四层备份恢复演练自动化 |
| **M5 打磨与 V1.0** | 四端一致性、无障碍、周期任务（可选）、官网 / 更新 / 脱敏崩溃上报 / 隐私政策、分发（Android 先） | 性能基线脚本（启动、唤起）；`Semantics` 审计；桌面自动更新（macOS Sparkle 或自建）、Android 官网 APK + 应用市场；隐私政策分"零服务 / 云中转"两口径 | M4 | 两周自用 Beta 无阻断缺陷 |

M6（会议模块）不在本计划内，V1.0 发布后按《PRD V1.2》第 10 章另立计划。

---

# 自审记录

1. **规格覆盖**：任务清单 V1 的 T0.1–T0.8 分别对应本计划任务 2、5、6、3+4、7、8、1+10、9；M1 T1.1–T1.13 全部出现在 M1 表；M2–M5 以里程碑表覆盖。设计 V2.2 第 5 章快捷键默认值在 T1.6 与任务 5/9 中一致（`⌥Space / ⌥⇧N / ⌥⇧V / ⌥⇧T / ⌥⇧S`）；第 6 章密钥规则在任务 4 与 M2 `SecretStore` 中一致；第 8 章同步语义在任务 7 与 M4 中一致；Web 端未出现在任何任务中。
2. **占位符扫描**：无 TBD / TODO；每个 M0 步骤都有代码或命令；M1 表给出精确签名而非"类似任务 N"。
3. **类型一致性**：`SeqDatabase.raw`（任务 3）被 T1.1 仓储使用；`Hlc / Operation / OpLog / FieldMerge / CryptoSession / LanChannel` 名称在任务 7 与 M4 一致；`SelectedTextService.getSelectedText()` 在任务 9 与 T1.6 / M2 一致；`NoteService` 方法名在 T1.2 / T1.7 / T1.10 / T1.12 一致。
4. **环境依赖**：Android 相关任务（6、部分 4、7 的真机验证）以《docs/开发环境准备清单.md》完成为前置，计划本身不安装任何软件。

---

# 执行交接

计划已保存到 `docs/superpowers/plans/2026-09-03-seqpoint-m0-m1-implementation-plan.md`。开始执行前需要所有者两项确认：① 允许在 `/Users/yiyi/development/SeqPoint` 执行 `git init`（任务 1 第 1 步）；② Android SDK 已按环境清单装好（任务 6 前置）。执行方式二选一：

1. **子代理驱动（推荐）**：每个任务派发一个全新子代理执行，任务之间做审查，迭代快 —— 使用 `superpowers:subagent-driven-development`。
2. **本会话内联执行**：按任务分批执行、每批设检查点 —— 使用 `superpowers:executing-plans`。
