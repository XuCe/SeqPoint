# 平台实现

`seqpoint_platform` 只定义接口，这里放各端实现，由 `platform_registry.dart` 装配。

计划的实现文件（随对应里程碑落地）：

| 文件 | 里程碑 | 说明 |
|---|---|---|
| `desktop_hotkeys.dart` | M1 | 全局快捷键（hotkey_manager） |
| `desktop_tray.dart` | M1 | 托盘 / 菜单栏（tray_manager）与开机自启 |
| `desktop_windows.dart` | M1 | 多窗口便签（window_manager + desktop_multi_window） |
| `desktop_notifications.dart` | M1 | 桌面系统通知（local_notifier） |
| `desktop_selected_text.dart` | M2 | 选中即整理：macOS Swift 通道 / Windows C++ 通道 |
| `mobile_notifications.dart` | M1 | 本地通知与动作按钮（flutter_local_notifications） |
| `mobile_widgets.dart` | M1 | 桌面 / 锁屏小组件（home_widget） |
| `mobile_share.dart` | M1 | 系统分享接入（receive_sharing_intent） |
| `mobile_quick_actions.dart` | M1 | 长按图标动作（quick_actions） |
| `secure_secret_store.dart` | M1 | Keychain / Keystore / DPAPI（flutter_secure_storage） |
| `syncthing_host_desktop.dart` | M4 | 按需下载引擎、校验签名、sidecar 启动 |
| `syncthing_host_android.dart` | M4 | 按需下载并以 libsyncthing 启动 |
