import '../../util/result.dart';

/// 同步通道抽象。搬运"单写者加密文件"，不理解内容。
///
/// 三种内置实现（纯 Dart，随应用打包，几百行）：
/// - [FolderTransport]  本地目录：网盘同步目录、NAS 挂载盘；
/// - [LanTransport]     局域网直连：mDNS 发现 + 设备间 HTTPS 拉取；
/// - [RelayTransport]   自建节点的 HTTPS 文件夹 API。
///
/// 可选的第四种是 Syncthing 引擎（按需下载，见 seqpoint_platform），
/// 负责跨网 P2P、中继与与用户现有 NAS 生态互通。
abstract interface class VaultTransport {
  String get id;

  /// 人类可读的状态，用于"仅本机 / 已同步到 N 台 / 待中转"的诚实展示。
  TransportStatus get status;

  /// 列出远端某设备目录下的文件名与大小。
  Future<Result<List<RemoteFile>>> list(String dirPath);

  /// 拉取一个文件。
  Future<Result<List<int>>> get(String filePath);

  /// 推送一个文件。实现必须校验只写本设备名下的路径（单写者）。
  Future<Result<void>> put(String filePath, List<int> bytes);

  /// 删除一个文件。仅用于回收本设备的旧段。
  Future<Result<void>> delete(String filePath);
}

class RemoteFile {
  const RemoteFile({required this.name, required this.size, this.modifiedAt});
  final String name;
  final int size;
  final DateTime? modifiedAt;
}

/// 同步状态。绝不虚报：没有可达副本时不能显示"已同步"。
class TransportStatus {
  const TransportStatus({
    required this.kind,
    this.peerCount = 0,
    this.lastSyncedAt,
    this.message,
  });

  final TransportStatusKind kind;
  final int peerCount;
  final DateTime? lastSyncedAt;
  final String? message;
}

enum TransportStatusKind {
  /// 仅本机，没有任何可达副本。
  localOnly,

  /// 正在同步。
  syncing,

  /// 已与 N 台设备收敛。
  synced,

  /// 已写入中转，等待对端取走。
  pendingRelay,

  /// 出错，需要用户注意。
  error,
}
