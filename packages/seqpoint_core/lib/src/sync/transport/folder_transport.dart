import 'dart:io';

import '../../util/result.dart';
import 'vault_transport.dart';

/// 本地目录通道：应用直接读写用户指定的目录。
///
/// 用途：把 Vault 放进 iCloud Drive / OneDrive / 坚果云的同步目录，
/// 或 NAS 的挂载盘。因为不存在并发写同一文件，网盘也不会产生冲突副本。
/// 这是零基础设施的备份与同步通道。
class FolderTransport implements VaultTransport {
  FolderTransport(this.root);

  final Directory root;

  @override
  String get id => 'folder';

  @override
  TransportStatus get status =>
      const TransportStatus(kind: TransportStatusKind.localOnly);

  @override
  Future<Result<List<RemoteFile>>> list(String dirPath) async {
    // TODO(M4)
    throw UnimplementedError();
  }

  @override
  Future<Result<List<int>>> get(String filePath) async =>
      throw UnimplementedError();

  @override
  Future<Result<void>> put(String filePath, List<int> bytes) async =>
      throw UnimplementedError();

  @override
  Future<Result<void>> delete(String filePath) async =>
      throw UnimplementedError();
}
