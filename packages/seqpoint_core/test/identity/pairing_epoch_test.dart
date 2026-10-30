import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'pairing_handshake_test.dart' show pairedFixture;

Future<void> confirmPair(PairingHandshake host, PairingHandshake guest) async {
  final hp = await host.confirmShortCode(host.shortCode), gp = await guest.confirmShortCode(guest.shortCode);
  await host.acceptConfirmation(gp); await guest.acceptConfirmation(hp);
}

const testCheckpointHash = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  test('缺本机或对端确认不发密钥，双端确认后才可交换', () async {
    final f = await pairedFixture(), key = VaultKey(epoch: 1, keyBytes: List.filled(32, 42));
    await expectLater(f.host.sealEpoch(key, checkpointHash: testCheckpointHash), throwsStateError);
    await expectLater(f.guest.openEpoch({}), throwsStateError);
    final hp = await f.host.confirmShortCode(f.host.shortCode);
    await f.guest.acceptConfirmation(hp);
    await expectLater(f.host.sealEpoch(key, checkpointHash: testCheckpointHash), throwsStateError);
    final gp = await f.guest.confirmShortCode(f.guest.shortCode);
    await f.host.acceptConfirmation(gp);
    final envelope = await f.host.sealEpoch(key, checkpointHash: testCheckpointHash), received = await f.guest.openEpoch(envelope);
    expect(received.epoch, 1); expect(received.keyBytes, key.keyBytes);
  });
  test('固定发送接收角色、冻结输入，交换只消费一次且返回只读密钥', () async {
    final f = await pairedFixture(); await confirmPair(f.host, f.guest);
    final bytes = List.filled(32, 42), key = VaultKey(epoch: 2, keyBytes: bytes);
    await expectLater(f.guest.sealEpoch(key, checkpointHash: testCheckpointHash), throwsStateError);
    await expectLater(f.host.openEpoch({}), throwsStateError);
    final sending = f.host.sealEpoch(key, checkpointHash: testCheckpointHash); bytes[0] = 0;
    final envelope = await sending;
    expect(() => envelope['ciphertext'] = 'changed', throwsUnsupportedError);
    expect(envelope.keys, unorderedEquals(['purpose', 'v', 'type', 'session_id', 'sender_id', 'recipient_id', 'ciphertext', 'checkpoint_hash']));
    expect(f.host.state, PairingHandshakeState.completed);
    await expectLater(f.host.sealEpoch(key, checkpointHash: testCheckpointHash), throwsStateError);
    final received = await f.guest.openEpoch(envelope);
    expect(received.epoch, 2); expect(received.keyBytes, List.filled(32, 42));
    expect(() => received.keyBytes.clear(), throwsUnsupportedError);
    expect(f.guest.state, PairingHandshakeState.completed);
    await expectLater(f.guest.openEpoch(envelope), throwsStateError);
  });
  test('本机无效Epoch参数不消耗ready会话，可纠正后发送', () async {
    final f = await pairedFixture(); await confirmPair(f.host, f.guest);
    for (final key in [VaultKey(epoch: 0, keyBytes: List.filled(32, 42)),
      VaultKey(epoch: 1, keyBytes: List.filled(31, 42)), VaultKey(epoch: 1, keyBytes: List.filled(32, 256))]) {
      await expectLater(f.host.sealEpoch(key, checkpointHash: testCheckpointHash), throwsArgumentError);
      expect(f.host.state, PairingHandshakeState.ready);
    }
    final packet = await f.host.sealEpoch(VaultKey(epoch: 1, keyBytes: List.filled(32, 42)), checkpointHash: testCheckpointHash);
    expect((await f.guest.openEpoch(packet)).keyBytes, List.filled(32, 42));
  });
  test('密文先于确认到达不解封，补齐确认后可接收原密文一次', () async {
    final f = await pairedFixture();
    final hp = await f.host.confirmShortCode(f.host.shortCode), gp = await f.guest.confirmShortCode(f.guest.shortCode);
    await f.host.acceptConfirmation(gp);
    final packet = await f.host.sealEpoch(VaultKey(epoch: 1, keyBytes: List.filled(32, 42)), checkpointHash: testCheckpointHash);
    await expectLater(f.guest.openEpoch(packet), throwsStateError);
    expect(f.guest.state, PairingHandshakeState.awaitingConfirmation);
    await f.guest.acceptConfirmation(hp);
    expect((await f.guest.openEpoch(packet)).keyBytes, List.filled(32, 42));
  });
  test('解封输入排队前冻结，之后修改原map不改变收到的密钥', () async {
    final f = await pairedFixture(); await confirmPair(f.host, f.guest);
    final wire = {...await f.host.sealEpoch(VaultKey(epoch: 1, keyBytes: List.filled(32, 42)), checkpointHash: testCheckpointHash)};
    final receiving = f.guest.openEpoch(wire); wire['ciphertext'] = 'changed';
    expect((await receiving).keyBytes, List.filled(32, 42));
  });
  test('异步封装期间取消或过期不发出密文，也不进入completed', () async {
    for (final expired in [false, true]) {
      final f = await pairedFixture(); await confirmPair(f.host, f.guest);
      final sending = f.host.sealEpoch(VaultKey(epoch: 1, keyBytes: List.filled(32, 42)), checkpointHash: testCheckpointHash);
      await Future<void>.value();
      if (expired) { f.clock.advance(const Duration(minutes: 11)); } else { f.host.cancel(); }
      await expectLater(sending, throwsStateError);
      expect(f.host.state, expired ? PairingHandshakeState.expired : PairingHandshakeState.cancelled);
    }
  });
  test('异步解封期间取消或过期不返回明文密钥', () async {
    for (final expired in [false, true]) {
      final f = await pairedFixture(); await confirmPair(f.host, f.guest);
      final envelope = await f.host.sealEpoch(VaultKey(epoch: 1, keyBytes: List.filled(32, 42)), checkpointHash: testCheckpointHash);
      final receiving = f.guest.openEpoch(envelope); await Future<void>.value();
      if (expired) { f.clock.advance(const Duration(minutes: 11)); } else { f.guest.cancel(); }
      await expectLater(receiving, throwsStateError);
      expect(f.guest.state, expired ? PairingHandshakeState.expired : PairingHandshakeState.cancelled);
    }
  });
}
