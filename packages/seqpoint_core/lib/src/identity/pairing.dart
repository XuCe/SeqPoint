/// QR 配对。新设备加入 Vault 的唯一途径，云端不参与密钥分发。
///
/// 流程（对应 PRD V1.1 §11.4）：
/// 1. 新设备本地生成密钥对，不向任何服务器注册；
/// 2. 已有设备创建一次性会话，展示二维码与短码；
/// 3. 两端通过通道交换公钥，**用户核对短码**防中间人；
/// 4. 可信设备把 Vault Key 封装后发给新设备；
/// 5. 写入签名的 deviceAdded 成员事件，随 Vault 同步到其他节点；
/// 6. 会话结束销毁全部临时状态。
class PairingSession {
  const PairingSession({
    required this.sessionId,
    required this.shortCode,
    required this.initiatorExchangePublicKey,
    required this.expiresAt,
  });

  final String sessionId;

  /// 供用户口头 / 目视核对的短码，如 "48-A2-91"。
  final String shortCode;

  final String initiatorExchangePublicKey;
  final DateTime expiresAt;

  /// 二维码承载的内容：只含临时标识、公钥材料与随机数，**不含 Vault Key**。
  Map<String, Object?> toQrPayload() => {
        'v': 1,
        'session': sessionId,
        'pub': initiatorExchangePublicKey,
        'exp': expiresAt.toIso8601String(),
      };
}

abstract interface class PairingCoordinator {
  /// 已有设备：发起配对，返回待展示的会话。
  Future<PairingSession> initiate();

  /// 新设备：扫码后应答，返回自己的公钥与短码以供核对。
  Future<String> respond(Map<String, Object?> qrPayload);

  /// 已有设备：用户确认短码一致后，封装并发送 Vault Key。
  Future<void> approve(String sessionId);

  void cancel(String sessionId);
}
