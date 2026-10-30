import 'dart:convert';
import 'package:seqpoint_core/src/identity/pairing_handshake.dart';
import 'package:test/test.dart';
import 'pairing_handshake_test.dart' show pairedFixture;

void main() {
  test('只有双方各自确认且对端凭据验证后才ready，确认消息无Epoch', () async {
    final f = await pairedFixture();
    final hp = await f.host.confirmShortCode(f.host.shortCode);
    expect(hp.keys, unorderedEquals(['purpose', 'v', 'type', 'session_id', 'sender_id', 'mac']));
    expect(() => hp['mac'] = 'changed', throwsUnsupportedError);
    expect(f.host.state, PairingHandshakeState.awaitingConfirmation);
    await f.guest.acceptConfirmation(hp);
    expect(f.guest.state, PairingHandshakeState.awaitingConfirmation);
    final gp = await f.guest.confirmShortCode(f.guest.shortCode);
    expect(f.guest.state, PairingHandshakeState.ready);
    expect(f.host.state, PairingHandshakeState.awaitingConfirmation);
    await f.host.acceptConfirmation(gp); expect(f.host.state, PairingHandshakeState.ready);
  });
  test('短码不符终止会话，不能再用正确短码继续', () async {
    final f = await pairedFixture(), code = f.host.shortCode;
    await expectLater(f.host.confirmShortCode(code == '00-00-00' ? 'FF-FF-FF' : '00-00-00'), throwsStateError);
    expect(f.host.state, PairingHandshakeState.cancelled);
    await expectLater(f.host.confirmShortCode(code), throwsStateError);
  });
  test('自己的确认不能反射为对端凭据，同身份另一会话MAC也不能混用', () async {
    final f = await pairedFixture(), other = await pairedFixture();
    final proof = await f.host.confirmShortCode(f.host.shortCode);
    await expectLater(f.host.acceptConfirmation(proof), throwsStateError);
    expect(f.host.state, PairingHandshakeState.cancelled);
    final peer = await f.guest.confirmShortCode(f.guest.shortCode);
    final moved = {...peer, 'session_id': other.invitation.sessionId};
    await expectLater(other.host.acceptConfirmation(moved), throwsStateError);
    expect(other.host.state, PairingHandshakeState.cancelled);
  });
  test('确认消息严格解析，非规范消息或坏MAC立即终止且不能ready', () async {
    for (final change in <void Function(Map<String, Object?>)>[
      (m) => m['extra'] = true, (m) => m['v'] = 1.0, (m) => m['purpose'] = 'other',
      (m) => m['type'] = 'response', (m) => m['mac'] = 'a' * 42,
    ]) {
      final f = await pairedFixture();
      final message = {...await f.guest.confirmShortCode(f.guest.shortCode)}; change(message);
      await expectLater(f.host.acceptConfirmation(message), throwsFormatException);
      expect(f.host.state, PairingHandshakeState.cancelled);
    }
    final f = await pairedFixture();
    final message = {...await f.guest.confirmShortCode(f.guest.shortCode),
      'mac': base64UrlEncode(List.filled(32, 7)).replaceAll('=', '')};
    await expectLater(f.host.acceptConfirmation(message), throwsStateError);
    expect(f.host.state, PairingHandshakeState.cancelled);
  });
  test('重复本机确认或对端确认不再发凭据，不毒化后续合法工作', () async {
    final f = await pairedFixture(), code = f.host.shortCode;
    await f.host.confirmShortCode(code);
    await expectLater(f.host.confirmShortCode(code), throwsStateError);
    final proof = await f.guest.confirmShortCode(f.guest.shortCode);
    await f.host.acceptConfirmation(proof);
    await expectLater(f.host.acceptConfirmation(proof), throwsStateError);
    expect(f.host.state, PairingHandshakeState.ready);
  });
  test('同队列确认先后可互通，收到的消息在排队前冻结', () async {
    final f = await pairedFixture();
    final hp = await f.host.confirmShortCode(f.host.shortCode);
    final local = f.guest.confirmShortCode(f.guest.shortCode), wire = {...hp};
    final peer = f.guest.acceptConfirmation(wire); wire['mac'] = 'changed';
    final gp = await local; await peer;
    expect(f.guest.state, PairingHandshakeState.ready);
    await f.host.acceptConfirmation(gp); expect(f.host.state, PairingHandshakeState.ready);
  });
  test('HMAC期间取消或过期不发出确认，过期后时钟回拨不复活', () async {
    for (final expires in [false, true]) {
      final f = await pairedFixture(), start = f.clock.now();
      final pending = f.host.confirmShortCode(f.host.shortCode);
      await Future<void>.value();
      if (expires) { f.clock.advance(const Duration(minutes: 11)); } else { f.host.cancel(); }
      await expectLater(pending, throwsStateError);
      f.clock.set(start);
      expect(f.host.state, expires ? PairingHandshakeState.expired : PairingHandshakeState.cancelled);
    }
  });
  test('验证对端HMAC期间取消不进入ready', () async {
    final f = await pairedFixture(), hp = await f.guest.confirmShortCode(f.guest.shortCode);
    final pending = f.host.acceptConfirmation(hp);
    await Future<void>.value(); f.host.cancel();
    await expectLater(pending, throwsStateError); expect(f.host.state, PairingHandshakeState.cancelled);
  });
}
