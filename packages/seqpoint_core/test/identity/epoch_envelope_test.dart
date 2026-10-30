import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'membership_fixture.dart';

void main() {
  test('封装在异步密码调用前冻结原始密钥和上下文', () async {
    final f = await membershipFixture(), bytes = List.filled(32, 42), context = [1, 2, 3];
    final sender = memberIdentity(f.founder, 'a'), recipient = memberIdentity(f.guest, 'b');
    final sealing = MemberEpochEnvelope.seal(sender: f.founder, senderIdentity: sender,
        recipient: recipient, context: context, epochKey: VaultKey(epoch: 1, keyBytes: bytes));
    bytes[0] = 0; context[0] = 0;
    final envelope = await sealing;
    final key = await envelope.open(recipient: f.guest, senderIdentity: sender,
        recipientIdentity: recipient, context: [1, 2, 3], epoch: 1);
    expect(key.keyBytes, List.filled(32, 42));
  });
  test('成员Epoch随机salt且AAD认证完整双方身份及变更上下文', () async {
    final f = await membershipFixture();
    final sender = memberIdentity(f.founder, 'a'), recipient = memberIdentity(f.guest, 'b');
    Future<MemberEpochEnvelope> seal() => MemberEpochEnvelope.seal(sender: f.founder,
        senderIdentity: sender, recipient: recipient, context: [1, 2, 3], epochKey: f.key);
    final a = await seal(), b = await seal();
    expect(a.salt, hasLength(32)); expect(a.frame, hasLength(72));
    expect(a.salt, isNot(b.salt)); expect(a.frame, isNot(b.frame));
    final restored = MemberEpochEnvelope.fromJson(a.toJson());
    final key = await restored.open(recipient: f.guest, senderIdentity: sender,
        recipientIdentity: recipient, context: [1, 2, 3], epoch: 1);
    expect(key.keyBytes, f.key.keyBytes);
    await expectLater(restored.open(recipient: f.guest, senderIdentity: sender,
        recipientIdentity: recipient, context: [1, 2, 3], epoch: 2), throwsStateError);
    await expectLater(restored.open(recipient: f.guest, senderIdentity: sender,
        recipientIdentity: recipient, context: [1, 2, 4], epoch: 1), throwsStateError);
    await expectLater(restored.open(recipient: f.guest, senderIdentity: sender,
        recipientIdentity: memberIdentity(f.guest, 'c'), context: [1, 2, 3], epoch: 1), throwsStateError);
    await expectLater(restored.open(recipient: f.founder, senderIdentity: sender,
        recipientIdentity: recipient, context: [1, 2, 3], epoch: 1), throwsStateError);
    expect(() => key.keyBytes[0] = 0, throwsUnsupportedError);
    expect(() => a.frame[0] = 0, throwsUnsupportedError);
  });
}
