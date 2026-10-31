# 完整版本更新

“应用更新”页提供热更新补丁和完整版本更新。完整版本只检查
`XuCe/SeqPoint` 的最新正式 GitHub Release；预览版不会推送给正式安装。
点击“下载并安装”后，由应用或原生更新窗口完成下载、校验和安装，
不打开浏览器，也不要求用户手动找安装包。

## 各平台

- Android：校验 GitHub 资产的 SHA256，再调用系统 PackageInstaller。
  用户需允许此应用安装更新，并按系统提示确认。下载阶段可以取消。
- macOS：Sparkle 验证 EdDSA 签名并安装。保留 App Sandbox；退出请求
  定向主 Flutter engine，等待同步结束，不能安全退出时取消。
  公开版使用固定的自签名身份和登录钥匙串，使不同版本保持同一钥匙串身份。
  从旧开发签名或临时签名版升级时，可能需要重新配置 API Key 和同步配对；
  本地笔记保留。如系统提示访问原应用数据，请允许。
  自签名应用未经 Apple 公证，首次打开需按系统安全提示手动允许。
- Windows：WinSparkle 验证 DSA 签名并运行每用户 Inno Setup 安装器。
  安装器不强制关闭应用；等待所有窗口进程退出，最多 120 秒，超时中止。
  首次建议使用 setup.exe；从便携 ZIP 更新会安装到标准用户目录，
  不会删除原 ZIP 解压目录，后续使用新建的“序点 SeqPoint”快捷方式。
- iOS：当前只有未签名归档，完整版本安装入口不可用。
- Linux：保留发布 tar.gz，暂不提供应用内完整安装。

安装前保存编辑并关闭便签窗口。应用数据库和附件位于应用数据目录，
安装器不删除该目录。安装失败不会被显示成“安装完成”。

## 发布

1. 修改 `apps/seqpoint_app/pubspec.yaml` 的版本和 build number，两者递增。
2. 先运行 release workflow 的手动预演；它不发布 Release 或 Shorebird 基线。
3. 正式 tag 与 pubspec 的版本号一致，例如 `0.2.0+2` 对应 `v0.2.0`。
4. CI 生成 APK、DMG、Windows setup.exe 和各自的签名 appcast。
   GitHub Release 全部资产上传后，客户端才能找到可安装更新。

新增 Secrets：`SPARKLE_PRIVATE_KEY`、`WINSPARKLE_PRIVATE_KEY`。
对应公钥在 macOS Info.plist 和 Windows runner/resources/update_dsa_pub.pem。
私钥必须持续保留和备份，不能随版本重新生成或加入仓库。
发布脚本是 `scripts/updates/appcast.py`；WinSparkle 0.8.1 使用其规定的
双 SHA-1 DSA 签名格式，macOS 使用 Sparkle 自带 sign_update。
这些更新签名不能代替 Apple Developer ID、公证或 Windows Authenticode。

macOS 构建还需要 `MACOS_SIGNING_P12_BASE64` 和 `MACOS_SIGNING_PASSWORD`。
始终使用同一自签名身份，并在安全位置备份加密的 P12 和密码；更换或丢失
身份会影响后续版本读取钥匙串与原有沙盒数据。CI 仅允许使用 GitHub 托管的
临时虚拟机，构建后删除 P12 和临时钥匙串，代码签名信任随虚拟机销毁。
证书公钥位于 `apps/seqpoint_app/macos/signing/seqpoint-certificate.pem`。

已安装的 v0.1.0 不含原生更新器，必须先完整安装一次新基线。
Shorebird 补丁不会增加本功能所需的原生插件或系统权限。
