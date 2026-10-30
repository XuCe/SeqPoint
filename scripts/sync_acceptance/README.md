# Mac 与 iOS 模拟器原生同步验收

从仓库根目录执行，需 Flutter、Go、Python 3.9+、Xcode 和已启动的 iOS 模拟器。测试使用隔离数据库、偏好及 Keychain 前缀；不使用个人笔记。仅测试入口绑定仓库测试证书、127.0.0.1 和指定端口，生产 TLS 校验不变。

1. 构建节点并启动宿主（保持此终端运行）：
   ```sh
   (cd node && go build -o /tmp/seqpoint-native-node .)
   dart scripts/sync_acceptance/host.dart /tmp/seqpoint-native-node
   ```
2. 将输出 `SETUP=` 后的路径设为 `SYNC_SETUP`，生成合成附件和两个客户端参数：
   ```sh
   export SYNC_SETUP=/宿主输出的临时目录/setup.json
   python3 scripts/sync_acceptance/make_fixtures.py "$SYNC_SETUP"
   python3 - <<'PY'
   import json, os, pathlib
   p = pathlib.Path(os.environ['SYNC_SETUP']); s = json.loads(p.read_text())
   for role in ['desktop', 'phone']:
       (p.parent / (role + '.json')).write_text(json.dumps({
           'SYNC_ROLE': role, 'SYNC_CONTROL': s['control'],
           'SYNC_RELAY': s[role], 'SYNC_CA': s['ca']}))
   PY
   ```
3. 在两个终端分别进入 `apps/seqpoint_app`，同时执行（将参数文件和模拟器 ID 换成实际值）：
   ```sh
   flutter test integration_test/native_sync_acceptance_test.dart -d macos --no-pub --dart-define-from-file=/临时目录/desktop.json --reporter expanded
   flutter test integration_test/native_sync_acceptance_test.dart -d 模拟器UUID --no-pub --dart-define-from-file=/临时目录/phone.json --reporter expanded
   ```
4. 查询宿主 `setup.json` 的 `control` 地址：`/phone-ready-background` 为 `true` 时，在模拟器 Controls → Home 将应用放入后台。`/desktop-background-edit-ready` 为 `true` 后，点击 Seqpoint App 回前台。期间电脑断言连续 70 秒手机无云请求；手机恢复后断言收到电脑修改。
5. 等两端均输出 `All tests passed!` 后、宿主仍运行时，执行最终断言：
   ```sh
   python3 scripts/sync_acceptance/verify.py "$SYNC_SETUP"
   ```
6. Ctrl-C 停止宿主。重新用 `lib/main.dart` 构建并安装正常应用，避免留下测试入口：`flutter build macos --debug --no-pub --target lib/main.dart` 和 `flutter build ios --simulator --debug --no-pub --target lib/main.dart`。确认不再需要证据后可删除宿主输出的专用临时目录。

## 2026-10-30 实测

- macOS 26.6.2 + iOS 27.1 模拟器，双原生客户端、真实 Go 节点、不同本地 HTTPS 入口；两端原生测试全部通过。
- 手机收到 19,664,928 字节 PNG，电脑收到 41,947,328 字节 M4A，原件 SHA-256 均一致。音频为有效一秒静音 M4A 加 40 MiB 随机 `free` box，验证原文件运输，不代表长录音采集测试。
- 手机第三个大块在 65,536 字节处断流，随后入口不可用 8 秒；自动恢复，双方成功下载的 blob 均只下载一次。接收阶段耗时电脑 77.152 秒、手机 186.199 秒，含自动调度/重试等待，不是网络吞吐基准。
- Home 后 70 秒无手机云请求；期间电脑修改并上传，手机回前台自动补齐。没有验证 iOS 杀进程后持续后台传输。
- 自动调度、媒体同步、进程重启续传和根生命周期另有针对性回归。证据摘要见 `result-2026-10-30.json`。
- 本地回环故障注入不能替代真实跨运营商/WAN、物理手机省电策略或移动网络限速实测，按用户要求留待真机接入。
