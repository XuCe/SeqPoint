/// Vault 目录布局。同步的对象是"单写者加密文件"，不是数据库。
///
/// ```text
/// seqpoint-vault/
/// ├── manifest.json                     明文：格式版本、Vault 公开 ID、当前 epoch
/// ├── members/<deviceId>.json           该设备签名的成员事件（明文可验签）
/// ├── ops/<deviceId>/<yyyymm>-<seq>.log 该设备的操作段：加密 + 签名，只有它自己写
/// ├── acks/<deviceId>.json              该设备已应用到各对端的水位
/// ├── attachments/<sha256>.bin          内容寻址的加密附件块，一次写入不改名
/// └── snapshots/<deviceId>-<epoch>.snap 该设备生成的加密全量快照
/// ```
///
/// 单写者原则：任何文件只有一台设备会创建、追加或删除，所以搬运方
/// （Syncthing / 网盘 / HTTPS）永远不会产生冲突文件。若出现
/// `.sync-conflict-*`，视为程序缺陷并告警。
abstract final class VaultLayout {
  static const manifestFile = 'manifest.json';
  static const membersDir = 'members';
  static const opsDir = 'ops';
  static const acksDir = 'acks';
  static const attachmentsDir = 'attachments';
  static const snapshotsDir = 'snapshots';

  /// 冲突文件的判定前缀，来自 Syncthing 与主流网盘的命名习惯。
  static const conflictMarkers = ['.sync-conflict-', ' (conflicted copy'];

  static String memberPath(String deviceId) => '$membersDir/$deviceId.json';

  static String ackPath(String deviceId) => '$acksDir/$deviceId.json';

  static String opsDirOf(String deviceId) => '$opsDir/$deviceId';

  /// 段文件名：`202609-0003.log`。按月份 + 序号，便于回收与排序。
  static String segmentName(int year, int month, int seq) {
    final mm = month.toString().padLeft(2, '0');
    final ss = seq.toString().padLeft(4, '0');
    return '$year$mm-$ss.log';
  }

  static String segmentPath(String deviceId, String segmentName) =>
      '${opsDirOf(deviceId)}/$segmentName';

  static String attachmentPath(String sha256) => '$attachmentsDir/$sha256.bin';

  static String snapshotName(String deviceId, int epoch) =>
      '$deviceId-$epoch.snap';

  static bool looksLikeConflict(String fileName) =>
      conflictMarkers.any(fileName.contains);
}

/// manifest.json 的内容。明文，不含任何密钥。
class VaultManifest {
  const VaultManifest({
    required this.formatVersion,
    required this.vaultPublicId,
    required this.keyEpoch,
  });

  static const currentFormatVersion = 1;

  final int formatVersion;

  /// 随机不透明标识，用于在节点上区分不同 Vault。不是用户名。
  final String vaultPublicId;

  final int keyEpoch;

  Map<String, Object?> toJson() => {
        'format_version': formatVersion,
        'vault_public_id': vaultPublicId,
        'key_epoch': keyEpoch,
      };

  factory VaultManifest.fromJson(Map<String, Object?> j) => VaultManifest(
        formatVersion: j['format_version'] as int,
        vaultPublicId: j['vault_public_id'] as String,
        keyEpoch: j['key_epoch'] as int,
      );
}
