/// 设备身份。没有传统账号：Vault 就是账号。
///
/// 两层身份：
/// - 应用密钥对（Ed25519 签名 + X25519 协商）：签成员变更、段、撤销事件；
/// - Syncthing Device ID（可选）：仅当启用引擎时用于传输层鉴权。
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.name,
    required this.signingPublicKey,
    required this.exchangePublicKey,
    this.syncthingDeviceId,
    this.isSelf = false,
    this.revokedAt,
    required this.addedAt,
  });

  /// 由签名公钥指纹派生的短 id。
  final String deviceId;

  /// 用户可读的设备名，如 "MacBook Pro"、"Pixel 8"。
  final String name;

  final String signingPublicKey;
  final String exchangePublicKey;

  /// 启用 Syncthing 引擎后填入，未启用为 null。
  final String? syncthingDeviceId;

  final bool isSelf;
  final DateTime? revokedAt;
  final DateTime addedAt;

  bool get isActive => revokedAt == null;
}

/// 成员事件。写入 `members/<deviceId>.json`，明文可验签。
class MembershipEvent {
  const MembershipEvent({
    required this.type,
    required this.subjectDeviceId,
    required this.issuerDeviceId,
    required this.keyEpoch,
    required this.signature,
    required this.at,
    this.payload,
  });

  final MembershipEventType type;
  final String subjectDeviceId;

  /// 签发者：必须是当时的可信成员。
  final String issuerDeviceId;

  final int keyEpoch;
  final String signature;
  final DateTime at;

  /// deviceAdded 时携带用对方公钥封装的 Vault Key。
  final Map<String, Object?>? payload;
}

enum MembershipEventType { deviceAdded, deviceRevoked, epochRotated }
