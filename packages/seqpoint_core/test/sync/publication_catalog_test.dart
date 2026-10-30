import 'dart:io';
import 'dart:async';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late Directory directory;
  late DeviceKeys keys;
  late EncryptedSegmentCodec codec;
  late SyncPublisher publisher;
  late SyncPublicationCatalog catalog;
  late MembershipReducer membership;
  var hasKey = true;
  setUp(() async {
    db = SeqDatabase.inMemory()..migrate();
    directory = Directory.systemTemp.createTempSync('catalog-');
    keys = await DeviceKeys.fromSeeds(List.filled(32, 8), List.filled(32, 9));
    final key = VaultKey(epoch: 1, keyBytes: List.filled(32, 10));
    membership = MembershipReducer(trustedAnchor: await MembershipState.createVault(
        founder: keys, vaultPublicId: 'catalog', epochKey: key, tlsFingerprint: 'a' * 64));
    codec = EncryptedSegmentCodec(vaultPublicId: 'catalog', deviceKeys: keys,
        epochKeys: {1: key.keyBytes}, trustedSigners: {keys.deviceId: keys.signer.publicKey});
    NoteRepository(db).insert(Note(id: 'n', kind: NoteKind.text, status: NoteStatus.active,
        rawContent: '临时可信目录', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    SyncBaseline(db).initialize(keys.deviceId);
    publisher = SyncPublisher(db, deviceId: keys.deviceId);
    hasKey = true;
    catalog = SyncPublicationCatalog(db, deviceId: keys.deviceId, policy: MembershipSyncPolicy(
        membership: membership, localDeviceId: keys.deviceId, hasEpochKey: (_) => hasKey));
  });
  tearDown(() { db.close(); directory.deleteSync(recursive: true); });
  Future<PublicationSnapshot> publish() async => (await publisher.publishNext(
      store: VaultStore(root: directory, deviceId: keys.deviceId, codec: codec), keyEpoch: 1))!;
  test('过量持久版本先拒绝，不把无界DB内容物化进内存', () async {
    final saved = await publish();
    db.transaction(() {
      for (var seq = 2; seq <= SyncPublicationCatalog.maxFiles + 1; seq++) {
        db.raw.execute('INSERT INTO sync_publications '
            '(seq,file_name,key_epoch,segment_bytes,sealed,published) VALUES (?,?,1,?,0,1)',
            [seq, 'bounded-$seq.log', saved.bytes]);
      }
    });
    await expectLater(catalog.refresh(codec: codec), throwsStateError);
    expect(catalog.snapshot(), isEmpty);
  });
  test('异步认证期间prepared替换或授权Epoch改变，旧目录不得提交且可重试', () async {
    await publish();
    await expectLater(catalog.refresh(codec: _DuringDecode(keys, codec, () async {
      db.raw.execute('UPDATE sync_publications SET published=0');
    })), throwsStateError);
    expect(catalog.snapshot(), isEmpty);
    db.raw.execute('UPDATE sync_publications SET published=1');
    await catalog.refresh(codec: codec);
    expect(catalog.snapshot(), hasLength(1));
    await expectLater(catalog.refresh(codec: _DuringDecode(keys, codec, () async {
      final rotate = await MembershipEvent.create(parent: membership.state,
          issuer: keys, type: MembershipEventType.rotate);
      await membership.ingest(rotate, issuerFileDeviceId: keys.deviceId);
    })), throwsStateError);
    expect(catalog.snapshot(), isEmpty);
  });
  test('停止立即关目录并排空已接受认证，拒绝所有新工作', () async {
    await publish();
    final entered = Completer<void>(), resume = Completer<void>();
    final pending = catalog.refresh(codec: _DuringDecode(keys, codec, () async {
      entered.complete(); await resume.future;
    }));
    await entered.future;
    final stopped = catalog.stop();
    expect(catalog.snapshot(), isEmpty);
    final rejected = expectLater(pending, throwsStateError);
    resume.complete(); await rejected; await stopped;
    await expectLater(catalog.refresh(codec: codec), throwsStateError);
  });
  test('目录不扫描磁盘，撤销可用性/恢复断开立即停止提供业务字节', () async {
    final saved = await publish();
    final path = 'ops/${keys.deviceId}/${saved.fileName}';
    File('${directory.path}/$path').writeAsBytesSync([99]);
    await catalog.refresh(codec: codec);
    expect(catalog.snapshot()[path], saved.bytes);
    hasKey = false;
    expect(catalog.snapshot(), isEmpty);
    hasKey = true;
    db.raw.execute('BEGIN');
    expect(catalog.snapshot, throwsStateError);
    db.raw.execute('ROLLBACK');
    expect(catalog.snapshot()[path], saved.bytes);
    db.disconnectSyncForRestore();
    expect(catalog.snapshot(), isEmpty);
  });
  test('DB坏签名与明文记录不能进入可信目录', () async {
    final saved = await publish(), segment = Segment.decode(savedBytes(db));
    for (final bytes in [segment.withPayload(segment.payload).encode(),
      segment.withPayload([...segment.payload]..[30] ^= 1, signature: segment.signature).encode()]) {
      db.raw.execute('UPDATE sync_publications SET segment_bytes=?', [bytes]);
      await expectLater(catalog.refresh(codec: codec), throwsStateError);
      expect(catalog.snapshot(), isEmpty);
    }
    db.raw.execute('UPDATE sync_publications SET segment_bytes=?', [saved.bytes]);
    await catalog.refresh(codec: codec);
    expect(catalog.snapshot(), hasLength(1));
  });
  test('目录只从已确认DB密文字节建立，prepared未发布不会暴露', () async {
    await publisher.prepare(codec: codec, keyEpoch: 1);
    await catalog.refresh(codec: codec);
    expect(catalog.snapshot(), isEmpty);
    final saved = (await publisher.publishNext(store: VaultStore(root: directory,
        deviceId: keys.deviceId, codec: codec), keyEpoch: 1))!;
    await catalog.refresh(codec: codec);
    final path = 'ops/${keys.deviceId}/${saved.fileName}';
    expect(catalog.snapshot()[path], saved.bytes);
    expect(() => catalog.snapshot()[path]!.clear(), throwsUnsupportedError);
  });
}

List<int> savedBytes(SeqDatabase db) => db.raw.select('SELECT segment_bytes FROM sync_publications')
    .single['segment_bytes'] as List<int>;

class _DuringDecode extends EncryptedSegmentCodec {
  _DuringDecode(DeviceKeys keys, this.delegate, this.before)
      : super(vaultPublicId: 'catalog', deviceKeys: keys, epochKeys: {1: List.filled(32, 10)},
          trustedSigners: {keys.deviceId: keys.signer.publicKey});
  final EncryptedSegmentCodec delegate;
  final Future<void> Function() before;
  @override
  Future<List<Operation>> decode(Segment segment) async {
    await before();
    return delegate.decode(segment);
  }
}
