import 'dart:convert';
import 'package:cryptography/cryptography.dart' show Sha256;
import '../db/database.dart';
import '../util/clock.dart';
import 'membership_sync_policy.dart';
import 'sync_inbox.dart';
import 'sync_projector.dart';
import 'vault/vault_store.dart';
import 'transport/lan_protocol.dart';

typedef SegmentApplyResult = ({int addedOperations, int appliedSeq, int pendingObjects, bool duplicate});

final class SyncAuthorizationBlocked extends StateError {
  SyncAuthorizationBlocked(this.check) : super('同步授权${check.decision.name}: ${check.reason}');
  final MembershipSyncCheck check;
}

/// 输入须来自Store单次认证读取；本方法只提交DB，不写ACK。
class SyncSegmentReceiver {
  /// 低层已授权输入及旧测试入口；应用接线须使用[SyncSegmentReceiver.authorized]。
  SyncSegmentReceiver(this._db, {Clock clock = const SystemClock()}) : _clock = clock, _policy = null,
      deviceId = _db.raw.select('SELECT device_id FROM sync_local WHERE id=1').single['device_id'] as String;
  SyncSegmentReceiver.authorized(this._db, {
    required MembershipSyncPolicy policy, Clock clock = const SystemClock(),
  }) : _clock = clock, _policy = policy,
      deviceId = _db.raw.select('SELECT device_id FROM sync_local WHERE id=1').single['device_id'] as String;
  final SeqDatabase _db;
  final Clock _clock;
  final MembershipSyncPolicy? _policy;
  final String deviceId;
  int get pendingObjects => _db.raw.select('SELECT pending_count FROM sync_local WHERE id=1').single['pending_count'] as int;
  Future<void> _ackTail = Future<void>.value();

  Map<String, int> get committedWatermarks {
    final result = <String, int>{};
    for (final row in _db.raw.select('SELECT device_id,applied_seq FROM sync_state '
        'WHERE applied_seq>0 ORDER BY device_id')) {
      final peer = row['device_id'] as String, seq = row['applied_seq'] as int;
      final checkpoints=_db.raw.select('SELECT * FROM sync_checkpoints WHERE author=?',[peer]);
      if(checkpoints.isNotEmpty && checkpoints.single['covered_seq']==seq) {
        final checkpoint=checkpoints.single;
        if(lanSha256(checkpoint['manifest_bytes'] as List<int>)!=checkpoint['manifest_hash']) {
          throw StateError('ACK checkpoint proof damaged');
        }
        result[peer]=seq; continue;
      }
      final receipts = _db.raw.select('SELECT * FROM sync_received_segments WHERE device_id=? AND seq=?', [peer, seq]);
      if (receipts.length != 1 || receipts.single['sealed'] != 1) throw StateError('ACK缺少封口收据');
      final receipt = receipts.single;
      final ids = (jsonDecode(receipt['op_ids_json'] as String) as List).cast<String>().toSet();
      final stored = _db.raw.select("SELECT op_id FROM sync_operations WHERE source='remote' "
          'AND device_id=? AND publication_seq=?', [peer, seq]).map((r) => r['op_id']).toSet();
      if (ids.length != receipt['op_count'] || stored.length != ids.length || !ids.every(stored.contains)) {
        throw StateError('ACK缺少持久操作证明');
      }
      result[peer] = seq;
    }
    return Map<String, int>.unmodifiable(result);
  }

  Future<SegmentApplyResult> receive(VerifiedSegment frame, {
    required Future<void> Function(Map<String, int>) writeAck,
  }) async {
    final result = await apply(frame);
    await retryAck(writeAck);
    return result;
  }

  Future<void> retryAck(Future<void> Function(Map<String, int>) writeAck) async {
    final attempt = _ackTail.then((_) async {
      final state = _db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
      if (!_db.raw.autocommit || state['device_id'] != deviceId ||
          state['enabled'] != 1 || state['requires_new_identity'] != 0) {
        throw StateError('ACK事务或身份状态无效');
      }
      _checkPolicy();
      // 异步写入的最终发布者仍须同步检查授权，回调前检查不覆盖I/O等待。
      await writeAck(committedWatermarks);
    });
    _ackTail = attempt.catchError((Object _) {});
    try { await attempt; }
    on SyncAuthorizationBlocked { rethrow; }
    catch (_) { throw StateError('数据已持久保存，ACK待重试'); }
  }

  Future<SegmentApplyResult> apply(VerifiedSegment frame) async {
    final s = frame.segment;
    if (!_db.raw.autocommit || s.seq < 1 || s.keyEpoch < 1 || !s.createdAt.isUtc ||
        s.opCount < 1 || s.opCount > 500 || s.opCount != frame.operations.length ||
        frame.operations.map((op) => op.opId).toSet().length != s.opCount ||
        frame.bytes.length > VaultStore.maxSegmentFileBytes) {
      throw StateError('同步段边界或事务状态无效');
    }
    _checkPolicy(frame);
    final hash = (await Sha256().hash(frame.bytes)).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (!_db.raw.autocommit) throw StateError('摘要期间事务状态改变，未接收本段');
    // 此检查至业务事务提交之间无await，摘要期间撤销/轮换不能跨过授权边界。
    _checkPolicy(frame);
    try {
      return _db.transaction<SegmentApplyResult>(() {
        final historyOnly = _checkPolicy(frame);
        final state = _db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
        if (state['enabled'] != 1 || state['requires_new_identity'] != 0 ||
            state['device_id'] != deviceId || state['device_id'] == s.deviceId) {
          throw StateError('同步尚未启用或作者无效');
        }
        final prior = _db.raw.select('SELECT applied_seq FROM sync_state WHERE device_id=?', [s.deviceId]);
        final applied = prior.isEmpty ? 0 : prior.single['applied_seq'] as int;
        final receipts = _db.raw.select('SELECT * FROM sync_received_segments WHERE device_id=? AND seq=?',
            [s.deviceId, s.seq]);
        final receipt = receipts.isEmpty ? null : receipts.single;
        if (receipt != null) _checkReceipt(frame, receipt);
        _checkOwnership(frame);
        if (applied < 0 || (s.seq > applied && s.seq != applied + 1)) throw StateError('段序号有缺口');
        if (s.seq <= applied) {
          if (receipt == null || receipt['sealed'] != 1 || receipt['segment_hash'] != hash) {
            throw StateError('封口段已改变或缺少收据');
          }
          return (addedOperations: 0, appliedSeq: applied,
              pendingObjects: state['pending_count'] as int, duplicate: true);
        }
        if (receipt?['sealed'] == 1) throw StateError('封口收据与水位不一致');
        if (receipt?['segment_hash'] == hash) {
          return (addedOperations: 0, appliedSeq: applied,
              pendingObjects: state['pending_count'] as int, duplicate: true);
        }
        final added = historyOnly ? 0 : SyncInbox(_db, clock: _clock)
            .storeVerifiedBatch(peerId: s.deviceId, operations: frame.operations);
        final pending = receipt == null || added > 0 ? SyncProjector(_db).project() : state['pending_count'] as int;
        if (!historyOnly) {
          for (final op in frame.operations) {
            _db.raw.execute('UPDATE sync_operations SET publication_seq=? WHERE op_id=?', [s.seq, op.opId]);
          }
        }
        _db.raw.execute('INSERT INTO sync_received_segments '
            '(device_id,seq,key_epoch,created_at,op_count,sealed,segment_hash,op_ids_json) VALUES (?,?,?,?,?,?,?,?) '
            'ON CONFLICT(device_id,seq) DO UPDATE SET op_count=excluded.op_count,'
            'sealed=excluded.sealed,segment_hash=excluded.segment_hash,op_ids_json=excluded.op_ids_json',
            [s.deviceId, s.seq, s.keyEpoch, encodeTime(s.createdAt), s.opCount, s.isSealed ? 1 : 0,
              hash, jsonEncode(frame.operations.map((op) => op.opId).toList())]);
        final next = s.isSealed ? s.seq : applied;
        _db.raw.execute('INSERT INTO sync_state(device_id,applied_seq,last_synced_at) VALUES (?,?,?) '
            'ON CONFLICT(device_id) DO UPDATE SET applied_seq=excluded.applied_seq,last_synced_at=excluded.last_synced_at',
            [s.deviceId, next, encodeTime(_clock.now())]);
        return (addedOperations: added, appliedSeq: next, pendingObjects: pending, duplicate: false);
      });
    } catch (_) { throw StateError('无法接收同步段，本段未提交'); }
  }

  bool _checkPolicy([VerifiedSegment? frame]) {
    final policy = _policy;
    if (policy == null) return false;
    final local = _db.raw.select('SELECT device_id FROM sync_local WHERE id=1').single['device_id'];
    if (local != deviceId || policy.localDeviceId != deviceId) {
      throw StateError('policy-local-id-mismatch');
    }
    final check = frame == null
        ? policy.checkLocalPublication(keyEpoch: policy.membership.state.epoch)
        : policy.checkInbound(peerDeviceId: frame.segment.deviceId, keyEpoch: frame.segment.keyEpoch);
    if (check.isAllowed) return false;
    if (frame != null && check.decision == MembershipSyncDecision.waiting &&
        _canSealKnownHistory(frame, policy)) { return true; }
    throw SyncAuthorizationBlocked(check);
  }

  // Historical ciphertext can only close an exact, already durable open prefix.
  bool _canSealKnownHistory(VerifiedSegment frame, MembershipSyncPolicy policy) {
    final s = frame.segment;
    if (!s.sealed || s.keyEpoch >= policy.membership.state.epoch ||
        !policy.checkSession(s.deviceId).isAllowed ||
        !policy.checkLocalPublication(keyEpoch: policy.membership.state.epoch).isAllowed ||
        !policy.hasEpochKey(s.keyEpoch)) { return false; }
    try {
      final receipts = _db.raw.select('SELECT * FROM sync_received_segments '
          'WHERE device_id=? AND seq=?', [s.deviceId, s.seq]);
      if (receipts.length != 1 || receipts.single['sealed'] != 0 ||
          receipts.single['op_count'] != s.opCount) { return false; }
      _checkReceipt(frame, receipts.single);
      _checkOwnership(frame);
      final prior = _db.raw.select('SELECT applied_seq FROM sync_state WHERE device_id=?', [s.deviceId]);
      return s.seq == (prior.isEmpty ? 0 : prior.single['applied_seq'] as int) + 1;
    } catch (_) { return false; }
  }

  void _checkReceipt(VerifiedSegment frame, Map<String, Object?> receipt) {
    final s = frame.segment;
    final ids = (jsonDecode(receipt['op_ids_json'] as String) as List).cast<String>();
    if (receipt['key_epoch'] != s.keyEpoch || receipt['created_at'] != encodeTime(s.createdAt) ||
        ids.length != receipt['op_count'] || ids.length > frame.operations.length) {
      throw StateError('段身份或前缀改变');
    }
    for (var i = 0; i < ids.length; i++) {
      if (frame.operations[i].opId != ids[i]) throw StateError('段操作前缀改变');
    }
    final stored = _db.raw.select("SELECT op_id FROM sync_operations WHERE source='remote' "
        'AND device_id=? AND publication_seq=?', [s.deviceId, s.seq]);
    final storedIds = stored.map((r) => r['op_id']).toSet();
    if (storedIds.length != ids.length || !ids.every(storedIds.contains)) {
      throw StateError('段收据缺少持久操作');
    }
  }

  void _checkOwnership(VerifiedSegment frame) {
    for (final op in frame.operations) {
      final rows = _db.raw.select('SELECT * FROM sync_operations WHERE op_id=?', [op.opId]);
      if (rows.isEmpty) continue;
      final row = rows.single;
      if (row['source'] != 'remote' || row['device_id'] != frame.segment.deviceId ||
          (row['publication_seq'] != null && row['publication_seq'] != frame.segment.seq) ||
          row['hlc_millis'] != op.hlc.millis || row['hlc_counter'] != op.hlc.counter ||
          row['object_type'] != op.objectType || row['object_id'] != op.objectId ||
          row['field'] != op.field || row['value_json'] != jsonEncode(op.value)) {
        throw StateError('操作已属于其他段或来源');
      }
    }
  }
}
