/// 可选的 Syncthing 引擎宿主。
///
/// 引擎不随安装包附带：用户首次开启"设备直连 / NAS 互通"时按需获取。
/// 桌面与 Android 官网版从自建服务器下载并校验签名；Play 版走动态模块；
/// iOS 首版不提供（只走精简通道）。
///
/// 首装体积增量为零，启用后约 +13 MB 磁盘。
abstract interface class SyncEngineHost {
  /// 本端是否支持引擎（iOS 首版返回 false）。
  bool get isSupported;

  /// 引擎是否已安装到应用数据目录。
  Future<bool> isInstalled();

  /// 下载并校验安装。[onProgress] 取值 0..1。
  Future<void> install({void Function(double progress)? onProgress});

  /// 启动引擎进程 / 服务，返回本机 REST 端点。
  Future<EngineEndpoint> start();

  Future<void> stop();

  /// 卸载并清理，回收磁盘。
  Future<void> uninstall();

  /// 配置引擎：加入 Vault 文件夹、添加对端设备、设置发现与中继地址。
  Future<void> configure({
    required String vaultFolderPath,
    required String vaultFolderId,
    required List<String> peerDeviceIds,
    String? discoveryUrl,
    String? relayUrl,
  });

  /// 本机 Syncthing Device ID，用于配对时交换。
  Future<String?> localDeviceId();
}

class EngineEndpoint {
  const EngineEndpoint({required this.baseUrl, required this.apiKey});
  final String baseUrl;
  final String apiKey;
}
