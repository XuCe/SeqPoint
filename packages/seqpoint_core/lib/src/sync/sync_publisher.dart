import 'dart:convert';

import '../db/database.dart';
import '../util/clock.dart';
import 'hlc.dart';
import 'operation.dart';
import 'operation_validation.dart';
import 'vault/encrypted_segment_codec.dart';
import 'vault/segment.dart';
import 'vault/vault_layout.dart';
import 'vault/vault_store.dart';

typedef PublicationSnapshot = ({
  int seq, String fileName, int keyEpoch, List<int> bytes,
  bool sealed, bool published, Segment header,
});
typedef FrozenSyncBatch = ({
  String deviceId, PublicationSnapshot? head, List<Operation> operations,
});

/// 冻结发布输入；编码与文件写入必须在本同步事务返回后执行。
class SyncPublisher {
  SyncPublisher(this._db, {required this.deviceId, Clock clock = const SystemClock()})
      : _clock = clock;
  final SeqDatabase _db;
  final String deviceId;
  final Clock _clock;
  Future<void> _publicationTail = Future<void>.value();
  bool _accepting = true;

  /// 同一主引擎串行准备、文件发布与确认；失败不阻塞下一次原bytes重试。
  Future<PublicationSnapshot?> publishNext({required VaultStore store, required int keyEpoch}) =>
      _enqueue(() => _publishNext(store, keyEpoch));

  /// A checkpoint covers only immutable sealed history; later edits get a new sequence.
  Future<PublicationSnapshot?> sealHead({required VaultStore store}) => _enqueue(() async {
    final frozen=freeze(), head=freeze().head;
    if(head==null || head.sealed) return head;
    if(!head.published) return _deliver(store,head);
    final existing=await store.codec.decode(Segment.decode(head.bytes));
    _checkCurrent(frozen); _checkBoundFacts(head,existing);
    final encoded=await store.codec.encode(Segment(deviceId:deviceId,keyEpoch:head.keyEpoch,
      seq:head.seq,opCount:existing.length,createdAt:head.header.createdAt,sealed:true,payload:const []),existing);
    return _deliver(store,_commitPrepared(frozen,encoded,const [],existing));
  });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    if (!_accepting) return Future<T>.error(StateError('同步发布器已停止'));
    final result = _publicationTail.then((_) => action());
    _publicationTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// 停止接受新工作，等待已接受的编码与文件IO结束后才能关闭/替换DB。
  Future<void> stop() {
    _accepting = false;
    return _publicationTail;
  }

  Future<PublicationSnapshot?> _publishNext(VaultStore store, int keyEpoch) async {
    if (store.deviceId != deviceId || keyEpoch < 1) throw StateError('发布Store身份或密钥版本无效');
    freeze();
    final history = _db.raw.select('SELECT seq,file_name FROM sync_publications ORDER BY seq');
    final names = {for (final row in history) row['file_name'] as String};
    final found = store.checkSelfHistory(names);
    PublicationSnapshot? missing;
    for (final row in history) {
      if (!found.contains(row['file_name'])) {
        missing = _readPublication(row['seq'] as int);
        break;
      }
    }
    final prepared = missing ?? await _prepare(codec: store.codec, keyEpoch: keyEpoch);
    if (prepared == null) return null;
    return _deliver(store, prepared);
  }

  Future<PublicationSnapshot> _deliver(VaultStore store, PublicationSnapshot prepared) async {
    final frozen = freeze();
    if (!_sameHead(_readPublication(prepared.seq), prepared)) throw StateError('待发布版本已改变');
    final names = _db.raw.select('SELECT file_name FROM sync_publications')
        .map((row) => row['file_name'] as String).toSet();
    late PublicationSnapshot published;
    await store.writePrepared(fileName: prepared.fileName, bytes: prepared.bytes,
        knownFileNames: names, commit: (operations, replace) {
      if (!_db.raw.autocommit) throw StateError('发布不能占用调用方事务');
      published = _db.transaction(() {
        _db.raw.execute('UPDATE sync_local SET id=id WHERE id=1');
        final state = _db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
        if (state['device_id'] != deviceId || state['enabled'] != 1 ||
            state['baseline_ready'] != 1 || state['requires_new_identity'] != 0) {
          throw StateError('发布身份或基线状态已改变');
        }
        final current = _readHead();
        _validateHistory(current);
        if (!_sameHead(current, frozen.head) ||
            !_sameHead(_readPublication(prepared.seq), prepared)) {
          throw StateError('待发布版本已改变');
        }
        _checkBoundFacts(prepared, operations);
        replace();
        _db.raw.execute('UPDATE sync_publications SET published=1 WHERE seq=?', [prepared.seq]);
        final result = _readPublication(prepared.seq)!;
        _checkBoundFacts(result, operations);
        return result;
      });
    });
    return published;
  }

  /// 加密/签名不占用DB事务；提交时重新核对冻结版本。
  Future<PublicationSnapshot?> prepare({required SegmentCodec codec, required int keyEpoch}) =>
      _enqueue(() => _prepare(codec: codec, keyEpoch: keyEpoch));

  Future<PublicationSnapshot?> _prepare({required SegmentCodec codec, required int keyEpoch}) async {
    if (keyEpoch < 1) throw StateError('发布密钥版本无效');
    final frozen = freeze();
    final head = frozen.head;
    var existing = const <Operation>[];
    if (head != null) {
      existing = List<Operation>.unmodifiable(await codec.decode(Segment.decode(head.bytes)));
      _checkCurrent(frozen);
      _checkBoundFacts(head, existing);
      if (!head.published) {
        return head;
      }
    }
    final now = _clock.now().toUtc();
    final append = head != null && !head.sealed;
    final prefix = append ? existing : const <Operation>[];
    var sealOld = append && (head.keyEpoch != keyEpoch ||
        head.header.createdAt.year != now.year || head.header.createdAt.month != now.month);
    final fit = sealOld ? (operations: const <Operation>[], full: true)
        : _fitOperations(prefix, frozen.operations);
    final selected = fit.operations;
    sealOld = sealOld || (append && fit.full);
    if (selected.isEmpty && frozen.operations.isNotEmpty) {
      if (!append) throw StateError('单个同步操作超限，仍保留待发布');
      sealOld = true;
    }
    if (selected.isEmpty && !sealOld) {
      _checkCurrent(frozen);
      return null;
    }
    final operations = List<Operation>.unmodifiable([...prefix, ...selected]);
    final encoded = await codec.encode(Segment(
        deviceId: deviceId, keyEpoch: append ? head.keyEpoch : keyEpoch,
        seq: append ? head.seq : (head?.seq ?? 0) + 1,
        opCount: operations.length, createdAt: append ? head.header.createdAt : now,
        sealed: sealOld || fit.full || selected.length < frozen.operations.length,
        payload: const []), operations);
    return _commitPrepared(frozen, encoded, selected, existing);
  }

  void _checkCurrent(FrozenSyncBatch frozen) {
    if (!_sameHead(freeze().head, frozen.head)) throw StateError('发布版本已改变，请重试');
  }

  ({List<Operation> operations, bool full}) _fitOperations(
      List<Operation> prefix, List<Operation> pending) {
    var size = 2;
    for (var i = 0; i < prefix.length; i++) {
      size += utf8.encode(jsonEncode(prefix[i].toJson())).length + (i == 0 ? 0 : 1);
    }
    if (size > EncryptedSegmentCodec.maxPlaintextBytes) throw StateError('已有同步段过大');
    final selected = <Operation>[];
    for (final op in pending) {
      if (prefix.length + selected.length >= Segment.maxOpsPerSegment) break;
      final cost = utf8.encode(jsonEncode(op.toJson())).length +
          (prefix.isEmpty && selected.isEmpty ? 0 : 1);
      if (size + cost > EncryptedSegmentCodec.maxPlaintextBytes) break;
      selected.add(op); size += cost;
    }
    return (operations: List<Operation>.unmodifiable(selected),
        full: size == EncryptedSegmentCodec.maxPlaintextBytes ||
            prefix.length + selected.length == Segment.maxOpsPerSegment);
  }

  PublicationSnapshot _commitPrepared(FrozenSyncBatch frozen, Segment encoded,
      List<Operation> selected, List<Operation> existing) {
    if (!_db.raw.autocommit) throw StateError('发布不能占用调用方事务');
    final bytes = encoded.encode();
    if (bytes.length > VaultStore.maxSegmentFileBytes) throw StateError('同步段文件过大');
    return _db.transaction(() {
      _db.raw.execute('UPDATE sync_local SET id=id WHERE id=1');
      final state = _db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
      if (frozen.deviceId != deviceId || state['device_id'] != deviceId ||
          state['enabled'] != 1 || state['baseline_ready'] != 1 ||
          state['requires_new_identity'] != 0) {
        throw StateError('发布身份或基线状态已改变');
      }
      final current = _readHead();
      _validateHistory(current);
      if (!_sameHead(current, frozen.head)) throw StateError('发布版本已改变，请重试');
      _checkBoundFacts(current, existing);
      _db.raw.execute('INSERT INTO sync_publications '
          '(seq,file_name,key_epoch,segment_bytes,sealed,published) VALUES (?,?,?,?,?,0) '
          'ON CONFLICT(seq) DO UPDATE SET segment_bytes=excluded.segment_bytes,'
          'sealed=excluded.sealed,published=0', [encoded.seq,
        VaultLayout.segmentName(encoded.createdAt.year, encoded.createdAt.month, encoded.seq),
        encoded.keyEpoch, bytes, encoded.sealed ? 1 : 0,
      ]);
      for (final op in selected) {
        final rows = _db.raw.select("SELECT * FROM sync_operations WHERE source='local' "
            'AND device_id=? AND op_id=? AND publication_seq IS NULL', [deviceId, op.opId]);
        if (rows.length != 1 || !_matchesFact(op, rows.single)) {
          throw StateError('冻结操作事实已改变');
        }
        _db.raw.execute("UPDATE sync_operations SET publication_seq=? WHERE source='local' "
            'AND device_id=? AND op_id=? AND publication_seq IS NULL',
            [encoded.seq, deviceId, op.opId]);
        if (_db.raw.updatedRows != 1) throw StateError('冻结操作绑定已改变');
      }
      final result = _readHead()!;
      _validateHistory(result);
      _checkBoundFacts(result, [if (current?.seq == encoded.seq) ...existing, ...selected]);
      return result;
    });
  }

  void _checkBoundFacts(PublicationSnapshot? head, List<Operation> prefix) {
    if (head == null) return;
    final rows = _db.raw.select("SELECT * FROM sync_operations WHERE source='local' "
        'AND publication_seq=?', [head.seq]);
    final bound = {for (final row in rows) row['op_id']: row};
    if (bound.length != prefix.length || prefix.length != head.header.opCount) {
      throw StateError('认证段与绑定事实不一致');
    }
    for (final op in prefix) {
      final row = bound.remove(op.opId);
      if (row == null || !_matchesFact(op, row)) throw StateError('认证段与绑定事实不一致');
    }
  }

  bool _matchesFact(Operation op, Map<String, Object?> row) {
    try {
      return row['op_id'] == op.opId && row['device_id'] == op.deviceId &&
          row['hlc_millis'] == op.hlc.millis && row['hlc_counter'] == op.hlc.counter &&
          row['object_type'] == op.objectType && row['object_id'] == op.objectId &&
          row['field'] == op.field &&
          jsonEncode(jsonDecode(row['value_json'] as String)) == jsonEncode(op.value);
    } catch (_) { return false; }
  }

  bool _sameHead(PublicationSnapshot? a, PublicationSnapshot? b) {
    if (a == null || b == null) return a == null && b == null;
    return (a.seq, a.fileName, a.keyEpoch, a.sealed, a.published) ==
        (b.seq, b.fileName, b.keyEpoch, b.sealed, b.published) &&
        a.bytes.length == b.bytes.length &&
        !a.bytes.indexed.any((entry) => entry.$2 != b.bytes[entry.$1]);
  }

  FrozenSyncBatch freeze() {
    if (!_db.raw.autocommit ||
        RegExp(r'^[A-Za-z0-9_-]{1,128}$').firstMatch(deviceId)?.end != deviceId.length) {
      throw StateError('发布身份或事务状态无效');
    }
    try {
      return _db.transaction(() {
        _db.raw.execute('UPDATE sync_local SET id=id WHERE id=1');
        final state = _db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
        if (state['device_id'] != deviceId || state['enabled'] != 1 ||
            state['baseline_ready'] != 1 || state['requires_new_identity'] != 0) {
          throw StateError('发布身份或基线状态无效');
        }
        if (_db.raw.select("SELECT 1 FROM sync_operations WHERE source='local' "
            'AND device_id<>? LIMIT 1', [deviceId]).isNotEmpty) {
          throw StateError('本机操作身份不一致');
        }
        final head = _readHead();
        _validateHistory(head);
        if (head != null && !head.published) {
          return (deviceId: deviceId, head: head, operations: const <Operation>[]);
        }
        final rows = _db.raw.select("SELECT * FROM sync_operations WHERE source='local' "
            'AND publication_seq IS NULL ORDER BY hlc_millis,hlc_counter LIMIT 500');
        final operations = rows.map((row) {
          final op = Operation(
            opId: row['op_id'] as String, deviceId: row['device_id'] as String,
            hlc: Hlc(millis: row['hlc_millis'] as int, counter: row['hlc_counter'] as int,
                deviceId: row['device_id'] as String),
            objectType: row['object_type'] as String, objectId: row['object_id'] as String,
            field: row['field'] as String, value: jsonDecode(row['value_json'] as String),
          );
          validateIncomingOperation(op, expectedDeviceId: deviceId);
          return op;
        });
        return (deviceId: deviceId, head: head,
            operations: List<Operation>.unmodifiable(operations));
      });
    } catch (_) {
      throw StateError('无法冻结同步发布，状态未改变');
    }
  }

  PublicationSnapshot? _readHead() {
    final rows = _db.raw.select('SELECT seq FROM sync_publications ORDER BY seq DESC LIMIT 1');
    return rows.isEmpty ? null : _readPublication(rows.single['seq'] as int);
  }

  PublicationSnapshot? _readPublication(int expectedSeq) {
    final rows = _db.raw.select('SELECT * FROM sync_publications WHERE seq=?', [expectedSeq]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final bytes = List<int>.unmodifiable(row['segment_bytes'] as List<int>);
    final split = bytes.indexOf(10);
    if (split < 0) throw const FormatException('发布头缺失');
    // 这里只读DB版本；验签与解密由后续事务外编码阶段负责。
    final header = Segment.decodeHeader(utf8.decode(bytes.sublist(0, split)));
    final seq = row['seq'] as int, epoch = row['key_epoch'] as int;
    final fileName = row['file_name'] as String;
    final sealed = row['sealed'] == 1;
    if (header.deviceId != deviceId || header.seq != seq || header.keyEpoch != epoch ||
        header.sealed != sealed || !header.createdAt.isUtc ||
        header.opCount < 1 || header.opCount > Segment.maxOpsPerSegment ||
        fileName != VaultLayout.segmentName(header.createdAt.year, header.createdAt.month, seq)) {
      throw StateError('发布头与历史不一致');
    }
    return (seq: seq, fileName: fileName, keyEpoch: epoch, bytes: bytes,
        sealed: sealed, published: row['published'] == 1, header: header);
  }

  void _validateHistory(PublicationSnapshot? head) {
    final checkpoints=_db.raw.select('SELECT local_floor FROM sync_checkpoints WHERE author=?',[deviceId]);
    final floor=checkpoints.isEmpty?0:checkpoints.single['local_floor'] as int;
    final count = _db.raw.select('SELECT COUNT(*) AS n FROM sync_publications').single['n'];
    if (count != (head?.seq ?? 0)-floor ||
        _db.raw.select('SELECT 1 FROM sync_publications WHERE seq<=? LIMIT 1',[floor]).isNotEmpty ||
        _db.raw.select('SELECT 1 FROM sync_publications WHERE seq<? '
            'AND (sealed=0 OR published=0) LIMIT 1', [head?.seq ?? 0]).isNotEmpty ||
        _db.raw.select('SELECT 1 FROM sync_operations o LEFT JOIN sync_publications p '
            "ON p.seq=o.publication_seq WHERE o.source='local' "
            'AND o.publication_seq>? AND p.seq IS NULL LIMIT 1',[floor]).isNotEmpty) {
      throw StateError('发布历史不连续或存在孤立绑定');
    }
    if (head != null) {
      final bound = _db.raw.select("SELECT COUNT(*) AS n FROM sync_operations WHERE source='local' "
          'AND publication_seq=?', [head.seq]).single['n'];
      if (bound != head.header.opCount) throw StateError('发布头与操作绑定计数不一致');
    }
  }
}
