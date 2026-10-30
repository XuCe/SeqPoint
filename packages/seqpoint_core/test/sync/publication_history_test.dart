import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'sync_publisher_test.dart' show addOperation;

List<int> addPublication(SeqDatabase db, int seq, {
  bool sealed = false, bool published = true,
}) {
  final bytes = Segment(deviceId: 'writer', keyEpoch: 2, seq: seq,
      opCount: 1, createdAt: DateTime.utc(2026, 10, 25), sealed: sealed,
      payload: [1, 2, 3]).encode();
  db.raw.execute('INSERT INTO sync_publications '
      '(seq,file_name,key_epoch,segment_bytes,sealed,published) VALUES (?,?,?,?,?,?)',
      [seq, VaultLayout.segmentName(2026, 10, seq), 2, bytes, sealed ? 1 : 0, published ? 1 : 0]);
  addOperation(db, seq * 1000);
  db.raw.execute('UPDATE sync_operations SET publication_seq=? WHERE op_id=?',
      [seq, 'writer:${seq * 1000}']);
  return bytes;
}

void main() {
  late SeqDatabase db;
  late SyncPublisher publisher;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    SyncBaseline(db).initialize('writer');
    publisher = SyncPublisher(db, deviceId: 'writer');
  });
  tearDown(() => db.close());

  test('序号缺口/非末段开放或未发布/孤立绑定/头计数不符均拒绝', () {
    for (final scenario in ['gap', 'open', 'prepared', 'orphan', 'count']) {
      db.raw.execute('DELETE FROM sync_operations');
      db.raw.execute('DELETE FROM sync_publications');
      if (scenario == 'orphan') {
        addOperation(db, 0);
        db.raw.execute('UPDATE sync_operations SET publication_seq=1');
      } else {
        addPublication(db, 1, sealed: scenario != 'open',
            published: scenario != 'prepared');
        if (scenario == 'count') {
          db.raw.execute('DELETE FROM sync_operations');
        } else {
          addPublication(db, scenario == 'gap' ? 3 : 2);
        }
      }
      expect(() => publisher.freeze(), throwsStateError, reason: scenario);
      expect(db.raw.autocommit, isTrue);
    }
  });

  test('合法已封口历史与末尾开放头使用全局序号', () {
    addPublication(db, 1, sealed: true);
    addPublication(db, 2);
    addOperation(db, 0, device: 'remote', source: 'remote');
    db.raw.execute("UPDATE sync_operations SET publication_seq=99 WHERE source='remote'");
    final batch = publisher.freeze();
    expect(batch.head!.seq, 2);
    expect(batch.head!.header.opCount, 1);
    expect(batch.operations, isEmpty);
  });

  test('prepared先重试原bytes，冻结版本不随数据库变化', () {
    final bytes = addPublication(db, 1, published: false);
    addOperation(db, 0);
    final batch = publisher.freeze();
    expect(batch.head!.published, isFalse);
    expect(batch.operations, isEmpty);
    db.raw.execute('UPDATE sync_publications SET published=1,segment_bytes=?', [[9]]);
    expect(batch.head!.bytes, bytes);
    expect(batch.head!.published, isFalse);
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NULL'), hasLength(1));
  });

  test('头与行的路径/epoch/封口/作者不一致或字节损坏均拒绝', () {
    final bytes = addPublication(db, 1);
    final other = Segment(deviceId: 'other', keyEpoch: 2, seq: 1, opCount: 1,
        createdAt: DateTime.utc(2026, 10, 25), payload: [1]).encode();
    for (final change in <String, Object>{
      'file_name': '../202610-0001.log', 'key_epoch': 3,
      'sealed': 1, 'segment_bytes': other,
    }.entries) {
      db.raw.execute('UPDATE sync_publications SET ${change.key}=?', [change.value]);
      expect(() => publisher.freeze(), throwsStateError, reason: change.key);
      db.raw.execute('UPDATE sync_publications SET file_name=?,key_epoch=2,sealed=0,segment_bytes=?',
          ['202610-0001.log', bytes]);
    }
    db.raw.execute('UPDATE sync_publications SET segment_bytes=?', [[0, 1]]);
    expect(() => publisher.freeze(), throwsStateError);
    expect(db.raw.autocommit, isTrue);
  });

  test('冻结开放头和原bytes版本，不把已绑定操作重复发布', () {
    final bytes = addPublication(db, 1);
    addOperation(db, 0);
    final batch = publisher.freeze();
    expect(batch.operations.single.opId, 'writer:0');
    expect(batch.head!.seq, 1);
    expect(batch.head!.fileName, '202610-0001.log');
    expect(batch.head!.keyEpoch, 2);
    expect(batch.head!.bytes, bytes);
    expect(batch.head!.header.createdAt, DateTime.utc(2026, 10, 25));
    expect(batch.head!.sealed, isFalse);
    expect(batch.head!.published, isTrue);
    expect(() => batch.head!.bytes[0] = 0, throwsUnsupportedError);
  });
}
