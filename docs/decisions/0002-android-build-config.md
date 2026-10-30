# ADR-0002 Android 构建配置

- 状态：已采纳（2026-09-05）
- 背景：首次 `flutter build apk` 失败，排查后确认是插件的构建要求未满足。

## 决定

`apps/seqpoint_app/android/app/build.gradle.kts` 三处非默认配置，都是插件的硬性要求：

| 配置 | 值 | 原因 |
|---|---|---|
| `compileSdk` | 37（不用 `flutter.compileSdkVersion`） | `receive_sharing_intent` 要求编译在 37。compileSdk 向后兼容，取各插件的最高要求即可 |
| `minSdk` | 26（不用 `flutter.minSdkVersion`） | 设计文档定的下限 Android 8.0；同时满足 `flutter_local_notifications`（24）与 `flutter_secure_storage`（23） |
| `isCoreLibraryDesugaringEnabled` | true，配 `desugar_jdk_libs:2.1.4` | `flutter_local_notifications` 用到 `java.time` 等新 API，低版本 Android 上必须靠 desugaring 兜底，缺了直接构建失败 |

`AndroidManifest.xml` 另加：

- `POST_NOTIFICATIONS` / `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM`：精确提醒是产品的强约束，必须准时触发；
- `RECEIVE_BOOT_COMPLETED` 与两个 `ScheduledNotification*Receiver`：否则重启手机会丢掉全部待触发的提醒；
- 两个 `ACTION_SEND` intent-filter：让"发送到序点"出现在系统分享菜单；
- `android:label="序点"`。

## 依赖清理（2026-09-05）

上游警告能消的都消了，做法不是等升级，而是换掉或去掉依赖：

| 插件 | 处理 | 原因 |
|---|---|---|
| `local_notifier` | **移除**，桌面通知改用 `flutter_local_notifications` | 前者最后发布于 2024-04，已停更，macOS 上用的是弃用的 `NSUserNotification`。后者已覆盖 macOS + Windows（经 `flutter_local_notifications_windows`），桌面与移动共用一套实现 |
| `package_info_plus` | **移除**，应用名与包名改为编译期常量 | 只用于给 `launch_at_startup` 传应用信息。其 10.x 需要 win32 ^6，与 `launch_at_startup` 依赖的 win32 ^5 冲突，升不动；而这点信息本来就不需要运行时查询 |
| `pasteboard` / `image_picker` | **移除** | 尚未使用（M1 图片功能才需要），先不背这个依赖 |

结果：Android 的 KGP 警告从 3 个（home_widget、package_info_plus、pasteboard）降到 1 个；
macOS 的 `NSUserNotification` 弃用警告消失。

## 仍待上游解决

- **`home_widget` 0.9.4 仍在用 KGP**（该版本发布于 2026-09-03，已是最新）。
  未来 Flutter 版本会拒绝构建。它承担的是移动端小组件，无可替代品，只能跟进上游：
  关注 https://pub.dev/packages/home_widget 的新版本，或在其仓库确认迁移进度。
  真到了构建被拒那天，退路是自己写小组件的平台通道（Android AppWidgetProvider +
  iOS WidgetKit），工作量不大但需要原生代码。
- macOS 的 `HotKey` Pod 有一条 Swift 协议扩展警告，来自 `hotkey_manager` 的依赖，
  不影响功能。

## 体积备注

Debug APK 约 158 MB，包含全部 ABI 与调试符号，**不代表发布体积**。
真实体积以 `flutter build apk --release --split-per-abi` 为准，届时再核。
