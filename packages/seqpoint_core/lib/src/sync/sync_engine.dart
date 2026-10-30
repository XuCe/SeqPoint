import '../util/result.dart';
import 'field_merge.dart';
import 'op_log.dart';
import 'operation.dart';
import 'segment_receiver.dart';
import 'vault/vault_store.dart';

/// 一次同步的结果。
class SyncOutcome {
  const SyncOutcome({
    required this.pulled,
    required this.pushed,
    required this.reclaimed,
    required this.peers,
    this.conflicts = const [],
    this.pendingObjects = 0,
    this.waitingPeers = const [],
  });

  /// 本轮从对端合并进来的操作条数。
  final int pulled;

  /// 本轮写出的操作条数。
  final int pushed;

  /// 回收的旧段数。
  final int reclaimed;

  /// 本轮见到的对端设备。
  final List<String> peers;

  /// 被并发覆盖的操作，写入 Activity 供用户回看。
  final List<Operation> conflicts;
  final int pendingObjects;
  final List<String> waitingPeers;

  bool get changed => pulled > 0 || pushed > 0;
}

/// 同步引擎：编排"扫描远端段 → 读缺口 → 合并 → 记水位 → 回收"。
///
/// 与传输无关：同一套流程可跑在本地目录、网盘、局域网或自建节点之上——
/// 差别只在 [VaultStore.root] 指向哪里。
class SyncEngine {
  /// 兼容历史内存测试；应用启用同步须选择persistent入口。
  SyncEngine({
    required this.store,
    required this.log,
    this.merge = const FieldMerge(),
  }) : _receiver = null;

  SyncEngine.persistent({required this.store, required SyncSegmentReceiver receiver})
      : _receiver = receiver, log = OpLog(), merge = const FieldMerge() {
    if (receiver.deviceId != store.deviceId) throw ArgumentError('Store与数据库身份不一致');
  }

  final SyncSegmentReceiver? _receiver;

  final VaultStore store;

  /// 本地已知的全部操作。合并的输入。
  final OpLog log;

  final FieldMerge merge;

  String get deviceId => store.deviceId;

  /// 把本地新产生的操作写入自己的段。
  Future<Result<int>> push(List<Operation> ops) async {
    if (ops.isEmpty) return const Ok(0);
    if (_receiver != null) {
      return const Err('persistent_publisher_required', message: '持久模式须通过事务Outbox发布器写段');
    }
    try {
      log.appendAll(ops);
      await store.append(ops);
      return Ok(ops.length);
    } catch (e) {
      return Err('push_failed', message: '写入本地段失败', cause: e);
    }
  }

  /// 跑一轮同步：拉取所有对端的缺口并合并。
  Future<Result<SyncOutcome>> syncOnce({Duration? reclaimTtl}) async {
    try {
      final receiver = _receiver;
      if (receiver != null) return Ok(await _syncPersistent(receiver));
      final devices = await store.knownDevices();
      final peers = devices.where((d) => d != deviceId).toList();

      // 最近读取的段仍可能追加，水位段需重读并由 opId 去重。
      final watermarks = Map<String, int>.from(await store.readAck(deviceId));

      var pulled = 0;
      for (final peer in peers) {
        final applied = watermarks[peer] ?? 0;
        var expected = applied > 0 ? applied : 1;
        final segments = await store.listSegments(peer);
        for (final segment in segments) {
          if (segment.seq < applied) continue;
          if (segment.seq != expected) break;
          final ops = await store.readOperations(peer, segment.seq);
          if (ops.length < segment.opCount) {
            throw StateError('日志段尚未完整到达：$peer/${segment.seq}');
          }
          for (final op in ops) {
            if (log.append(op)) pulled++;
          }
          watermarks[peer] = segment.seq;
          if (!segment.isSealed) break;
          expected = segment.seq + 1;
        }
      }

      await store.writeSelfAck(watermarks);

      return Ok(SyncOutcome(
        pulled: pulled,
        pushed: 0,
        reclaimed: 0, // V1 要求覆盖快照；当前保留全部段，不自动回收。
        peers: peers,
        conflicts: merge.losers(log.all),
      ));
    } catch (e) {
      return Err('sync_failed', message: '同步失败', cause: e);
    }
  }

  Future<SyncOutcome> _syncPersistent(SyncSegmentReceiver receiver) async {
    if (receiver.deviceId != deviceId) throw StateError('同步身份不一致');
    final peers = (await store.knownDevices()).where((id) => id != deviceId).toList();
    final watermarks = receiver.committedWatermarks;
    final waitingPeers = <String>{};
    var pulled = 0;
    for (final peer in peers) {
      var expected = (watermarks[peer] ?? 0) + 1;
      final segments = await store.listSegments(peer);
      for (final listed in segments) {
        if (listed.seq < expected) continue;
        if (listed.seq != expected) { waitingPeers.add(peer); break; }
        final verified = await store.readVerifiedSegment(peer, listed.seq);
        if (verified == null) { waitingPeers.add(peer); break; }
        final result = await receiver.apply(verified);
        pulled += result.addedOperations;
        if (!verified.segment.isSealed) {
          if (segments.any((s) => s.seq > listed.seq)) waitingPeers.add(peer);
          break;
        }
        expected = result.appliedSeq + 1;
      }
    }
    await receiver.retryAck(store.writeSelfAck);
    return SyncOutcome(pulled: pulled, pushed: 0, reclaimed: 0, peers: peers,
        pendingObjects: receiver.pendingObjects, waitingPeers: waitingPeers.toList());
  }

  /// 合并后的对象状态：{(type,id): {field: value}}。
  Map<SyncObjectKey, Map<String, Object?>> materialize() {
    if (_receiver != null) throw StateError('持久模式请读取业务仓储');
    return merge.materialize(log.all);
  }
}
