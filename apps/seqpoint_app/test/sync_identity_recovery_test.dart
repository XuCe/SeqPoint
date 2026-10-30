import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/sync_identity_store.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  String? value;
  bool dropWrite = false;
  bool writeThenFail = false;
  @override
  Future<String?> read(String key) async => value;
  @override
  Future<void> write(String key, String record) async {
    if (!dropWrite) value = record;
    if (writeThenFail) throw StateError('fake write error');
  }
}

void main() {
  test('explicit recovery always creates a fresh identity and preserves every prior key', () async {
    final secrets = _Secrets(), store = SyncIdentityStore(_Secrets());
    final own = SyncIdentityStore(secrets);
    final original = await own.loadOrCreate('old');
    final first = await own.createRecoveryIdentity('new');
    final second = await SyncIdentityStore(secrets).createRecoveryIdentity('newer');
    expect({original.keys.deviceId, first.keys.deviceId, second.keys.deviceId}, hasLength(3));
    final restored = await SyncIdentityStore(secrets).loadForDevice(original.keys.deviceId);
    expect(await restored.keys.signer.sign([1]), await original.keys.signer.sign([1]));
    expect((await SyncIdentityStore(secrets).loadForDevice(first.keys.deviceId)).keys.deviceId, first.keys.deviceId);
    expect(jsonDecode(secrets.value!)['identities'], hasLength(3));
    expect((await store.loadOrCreate('unrelated')).identity.name, 'unrelated');
  });

  test('failed readback never returns a candidate and a later begin does not reuse it', () async {
    final secrets = _Secrets(), store = SyncIdentityStore(_Secrets());
    final own = SyncIdentityStore(secrets), old = await own.loadOrCreate('old');
    final before = secrets.value;
    secrets.dropWrite = true;
    await expectLater(own.createRecoveryIdentity('dropped'), throwsStateError);
    expect(secrets.value, before);
    secrets.dropWrite = false; secrets.writeThenFail = true;
    await expectLater(own.createRecoveryIdentity('uncertain'), throwsStateError);
    secrets.writeThenFail = false;
    await own.createRecoveryIdentity('fresh');
    expect(jsonDecode(secrets.value!)['identities'], hasLength(3));
    expect((await own.loadForDevice(old.keys.deviceId)).keys.deviceId, old.keys.deviceId);
    await expectLater(store.loadForDevice(old.keys.deviceId), throwsStateError);
  });

  test('duplicate identities, damaged history and capacity limits preserve the record', () async {
    final secrets = _Secrets(), own = SyncIdentityStore(_Secrets());
    final store = SyncIdentityStore(secrets);
    await store.loadOrCreate('old');
    final single = jsonDecode(secrets.value!) as Map;
    final records = [for (var n = 1; n <= SyncIdentityStore.maxIdentities; n++)
      {...single, 'signing_seed': base64Encode(List.filled(32, n)),
        'exchange_seed': base64Encode(List.filled(32, n + 100))}];
    secrets.value = jsonEncode({'v': 2, 'identities': records});
    final full = secrets.value;
    await expectLater(store.createRecoveryIdentity('overflow'), throwsStateError);
    expect(secrets.value, full);
    for (final invalid in [
      jsonEncode({'v': 2, 'identities': [single, single]}),
      jsonEncode({'v': 2, 'identities': [single, {...single, 'exchange_seed': 'bad'}]}),
      jsonEncode({'v': 2, 'identities': [single], 'unexpected': true}),
      ' ' * (SyncIdentityStore.maxRecordChars + 1),
    ]) {
      secrets.value = invalid;
      await expectLater(SyncIdentityStore(secrets).loadOrCreate('ignored'), throwsStateError);
      await expectLater(SyncIdentityStore(secrets).createRecoveryIdentity('ignored'), throwsStateError);
      expect(secrets.value, invalid);
    }
    expect((await own.loadOrCreate('other')).identity.name, 'other');
  });
}
