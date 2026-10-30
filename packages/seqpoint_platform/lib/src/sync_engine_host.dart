/// 随应用打包的 Syncthing 引擎宿主。
/// 移动端通过原生桥运行；桌面端管理独立子进程。
abstract interface class SyncEngineHost {
  /// 本端是否支持引擎。
  bool get isSupported;

  /// 当前应用是否包含可用引擎。
  Future<bool> isInstalled();

  /// 验证随应用打包的引擎。[onProgress] 取值 0..1。
  Future<void> install({void Function(double progress)? onProgress});

  /// 启动引擎进程 / 服务，返回本机 REST 端点。
  Future<EngineEndpoint> start();

  Future<void> stop();

  /// 不可单独卸载的内置引擎抛出 UnsupportedError。
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
