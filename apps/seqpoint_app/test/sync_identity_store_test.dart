import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/sync_identity_store.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

void main() {
  test('单一安全记录保存双私钥，重开身份与时间不变', () async {
    final secrets = _Secrets();
    final first = await SyncIdentityStore(secrets).loadOrCreate('电脑');
    expect(first.identity.isSelf, isTrue);
    expect(first.identity.name, '电脑');
    expect(first.identity.deviceId, first.keys.deviceId);
    expect(base64Decode(first.identity.signingPublicKey), first.keys.signer.publicKey);
    expect(secrets.values, hasLength(1));
    final again = await SyncIdentityStore(secrets).loadOrCreate('其他名称');
    expect(again.identity.deviceId, first.identity.deviceId);
    expect(again.identity.addedAt, first.identity.addedAt);
    expect(again.identity.name, '电脑');
    expect(await again.keys.signer.sign([1]), await first.keys.signer.sign([1]));
  });
  test('同一主引擎并发加载只创建一个身份', () async {
    final secrets = _Secrets();
    final store = SyncIdentityStore(secrets);
    final values = await Future.wait([
      store.loadOrCreate('电脑'), store.loadOrCreate('电脑'),
    ]);
    expect(values[0].identity.deviceId, values[1].identity.deviceId);
    expect(secrets.writes, 1);
  });
  test('读写失败脱敏且可重试，不缓存失败结果', () async {
    final secrets = _Secrets()..failRead = true;
    final store = SyncIdentityStore(secrets);
    final safeError = predicate((e) => e is StateError &&
        !e.toString().contains('private-test-value'));
    await expectLater(store.loadOrCreate('电脑'), throwsA(safeError));
    expect(secrets.writes, 0);
    secrets.failRead = false;
    secrets.failWrite = true;
    await expectLater(store.loadOrCreate('电脑'), throwsA(safeError));
    expect(secrets.values, isEmpty);
    secrets.failWrite = false;
    expect((await store.loadOrCreate('电脑')).identity.name, '电脑');
    expect(secrets.writes, 2);
  });
  test('损坏记录拒绝，绝不静默生成替代身份或覆盖现场', () async {
    final valid = _Secrets();
    await SyncIdentityStore(valid).loadOrCreate('电脑');
    final data = jsonDecode(valid.values.values.single) as Map<String, dynamic>;
    for (final record in [
      'not-json', '{}',
      jsonEncode({...data, 'v': 2}),
      jsonEncode({...data, 'signing_seed': 'secret-bad-value'}),
      jsonEncode({...data, 'exchange_seed': base64Encode([1])}),
      jsonEncode({...data, 'added_at': 'bad-date'}),
      jsonEncode({...data, 'name': ''}),
    ]) {
      final secrets = _Secrets()..values[SyncIdentityStore.storageKey] = record;
      await expectLater(SyncIdentityStore(secrets).loadOrCreate('电脑'),
          throwsStateError);
      expect(secrets.values.values.single, record);
      expect(secrets.writes, 0);
    }
  });
  test('写后报错保留原身份，回读不一致不返回可用身份', () async {
    final secrets = _Secrets()..writeThenFail = true;
    final store = SyncIdentityStore(secrets);
    await expectLater(store.loadOrCreate('电脑'), throwsStateError);
    final saved = secrets.values.values.single;
    secrets.writeThenFail = false;
    final retried = await store.loadOrCreate('电脑');
    final reopened = await SyncIdentityStore(secrets).loadOrCreate('电脑');
    expect(retried.identity.deviceId, reopened.identity.deviceId);
    expect(secrets.values.values.single, saved);
    expect(secrets.writes, 1);
    final dropped = _Secrets()..dropWrite = true;
    await expectLater(SyncIdentityStore(dropped).loadOrCreate('电脑'),
        throwsStateError);
    expect(dropped.values, isEmpty);
  });
  test('非法新设备名不写安全存储', () async {
    final secrets = _Secrets();
    for (final name in ['', 'a\nb', 'a' * 81]) {
      await expectLater(SyncIdentityStore(secrets).loadOrCreate(name),
          throwsStateError);
    }
    expect(secrets.writes, 0);
  });
}

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  int writes = 0;
  bool failRead = false, failWrite = false;
  bool writeThenFail = false, dropWrite = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('private-test-value');
    return values[key];
  }
  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (failWrite) throw StateError('private-test-value');
    if (dropWrite) return;
    values[key] = value;
    if (writeThenFail) throw StateError('private-test-value');
  }
}
