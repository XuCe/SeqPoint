import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/sync_tls_store.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

void main() {
  test('single secure record persists TLS material and concurrent loads agree', () async {
    final secrets = _Secrets();
    final store = SyncTlsStore(secrets);
    final values = await Future.wait([store.loadOrCreate(), store.loadOrCreate()]);
    expect(values[0].fingerprint, values[1].fingerprint);
    expect(secrets.writes, 1);
    expect(secrets.values.keys, [SyncTlsStore.storageKey]);
    final data = jsonDecode(secrets.values.values.single) as Map;
    expect(data.keys.toSet(), {'v', 'certificate_pem', 'private_key_pem', 'fingerprint'});
    final reopenedSecrets = _Secrets()..values.addAll(secrets.values);
    final reopened = await SyncTlsStore(reopenedSecrets).loadOrCreate();
    expect(reopened.fingerprint, values[0].fingerprint);
    expect(reopened.privateKeyPem, values[0].privateKeyPem);
    expect(reopened.certificatePem, values[0].certificatePem);
    expect(reopenedSecrets.writes, 0);
  });
  test('damaged records are rejected without replacing or exposing them', () async {
    final valid = _Secrets();
    await SyncTlsStore(valid).loadOrCreate();
    final data = jsonDecode(valid.values.values.single) as Map<String, dynamic>;
    for (final record in [
      'not-json', '{}', 'x' * 32769,
      jsonEncode({...data, 'v': 2}), jsonEncode({...data, 'v': 1.0}),
      jsonEncode({...data, 'extra': true}),
      jsonEncode({...data, 'certificate_pem': 'private-test-value'}),
      jsonEncode({...data, 'private_key_pem': 'private-test-value'}),
      jsonEncode({...data, 'fingerprint': '0' * 64}),
      jsonEncode({...data, 'fingerprint': 'A' * 64}),
    ]) {
      final secrets = _Secrets()..values[SyncTlsStore.storageKey] = record;
      await expectLater(SyncTlsStore(secrets).loadOrCreate(),
          throwsA(predicate((e) => e is StateError &&
              !e.toString().contains('private-test-value'))));
      expect(secrets.values.values.single, record);
      expect(secrets.writes, 0);
    }
  });
  test('read and write failures are safe to retry without caching failure', () async {
    final secrets = _Secrets()..failRead = true;
    final store = SyncTlsStore(secrets);
    final safeError = throwsA(predicate((e) => e is StateError &&
        !e.toString().contains('private-test-value')));
    await expectLater(store.loadOrCreate(), safeError);
    expect(secrets.writes, 0);
    secrets.failRead = false;
    secrets.failWrite = true;
    await expectLater(store.loadOrCreate(), safeError);
    expect(secrets.values, isEmpty);
    secrets.failWrite = false;
    expect((await store.loadOrCreate()).fingerprint, hasLength(64));
    expect(secrets.writes, 2);
  });
  test('write acknowledgement failure reopens saved identity; dropped writes fail', () async {
    final secrets = _Secrets()..writeThenFail = true;
    final store = SyncTlsStore(secrets);
    await expectLater(store.loadOrCreate(), throwsStateError);
    final saved = secrets.values.values.single;
    secrets.writeThenFail = false;
    final recovered = await store.loadOrCreate();
    expect((await SyncTlsStore(secrets).loadOrCreate()).fingerprint,
        recovered.fingerprint);
    expect(secrets.values.values.single, saved);
    expect(secrets.writes, 1);
    final dropped = _Secrets()..dropWrite = true;
    await expectLater(SyncTlsStore(dropped).loadOrCreate(), throwsStateError);
    expect(dropped.values, isEmpty);
  });
  test('parallel stores sharing one secure backend create one identity', () async {
    final secrets = _Secrets();
    final values = await Future.wait([
      SyncTlsStore(secrets).loadOrCreate(), SyncTlsStore(secrets).loadOrCreate(),
    ]);
    expect(values[0].fingerprint, values[1].fingerprint);
    expect(secrets.writes, 1);
  });
  test('cached or reopened expired material is rejected and preserved', () async {
    final secrets = _Secrets();
    final clock = _Clock(DateTime.now().toUtc());
    final store = SyncTlsStore(secrets, clock: clock);
    final identity = await store.loadOrCreate();
    final saved = secrets.values.values.single;
    clock.value = identity.notAfter;
    await expectLater(store.loadOrCreate(), throwsStateError);
    await expectLater(SyncTlsStore(secrets, clock: clock).loadOrCreate(),
        throwsStateError);
    expect(secrets.writes, 1);
    expect(secrets.values.values.single, saved);
  });
}

class _Clock implements Clock {
  _Clock(this.value);
  DateTime value;
  @override
  DateTime now() => value;
}

class _Secrets implements SecretStore {
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
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);
}
