/// Vault 密钥与轮换。
///
/// 层级（对应同步方案第 3 章）：
/// ```text
/// Recovery Seed（用户离线保存）
///        ↓ HKDF
/// Recovery Wrapping Key
///        ↓
/// Vault Epoch Key ── 加密 ops / attachments / snapshots
///        ↓
/// Item Key / Attachment Key
/// ```
///
/// Epoch Key 只存在可信设备的系统安全存储，绝不落数据库、日志或导出文件。
class VaultKey {
  const VaultKey({required this.epoch, required this.keyBytes});

  /// 密钥世代。撤销设备后 +1，新数据只对未撤销设备可读。
  final int epoch;

  /// 32 字节对称密钥。仅在内存中短暂存在。
  final List<int> keyBytes;
}

/// 密钥轮换。撤销设备时调用。
abstract interface class KeyRotation {
  /// 生成新 epoch 的 Vault Key，并用每台未撤销设备的 X25519 公钥封装。
  ///
  /// 注意产品口径：撤销阻止未来访问，**不等于**擦除对方已持有的历史数据。
  Future<VaultKey> rotate({
    required int currentEpoch,
    required List<String> activeDeviceExchangeKeys,
  });
}

/// 恢复密钥。
///
/// 关键澄清：Recovery Key 是"打开已有数据副本的钥匙"，不是数据本身。
/// 若所有设备丢失、无私有节点、无导出备份，则无法凭它凭空恢复。
abstract interface class RecoveryKey {
  /// 首次创建 Vault 时生成高熵种子，并要求用户确认已保存。
  Future<String> generateSeed();

  /// 用种子解封加密备份或快照。
  Future<VaultKey> unwrap(String seed, List<int> wrappedKey);
}
