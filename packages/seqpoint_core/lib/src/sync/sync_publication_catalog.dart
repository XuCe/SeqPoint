import 'package:collection/collection.dart';
import '../db/database.dart';
import 'membership_sync_policy.dart';
import 'vault/encrypted_segment_codec.dart';
import 'vault/segment.dart';
import 'vault/vault_layout.dart';
import 'vault/vault_store.dart';

/// 从持久published版本建立可信目录；不读取搬运目录中的任何文件。
class SyncPublicationCatalog {
  SyncPublicationCatalog(this._db, {required this.deviceId, required this.policy}) {
    if (deviceId != policy.localDeviceId) throw ArgumentError('目录与授权身份不符');
  }
  static const maxCatalogBytes = 64 * 1024 * 1024;
  static const maxFiles = 1000;
  final SeqDatabase _db;
  final String deviceId;
  final MembershipSyncPolicy policy;
  Map<String, List<int>> _files = const {};
  int? _epoch;
  bool _accepting = true;
  Future<void> _tail = Future<void>.value();

  Map<String, List<int>> snapshot() {
    if (!_accepting || _epoch != policy.membership.state.epoch || !_allowed()) return const {};
    if (!_db.raw.autocommit) throw StateError('不能暴露未提交的目录');
    return _enabled() ? _files : const {};
  }

  Future<void> refresh({required EncryptedSegmentCodec codec}) {
    if (!_accepting) return Future.error(StateError('可信目录已停止'));
    final result = _tail.then((_) => _refresh(codec));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
  Future<void> stop() {
    _accepting = false;
    _files = const {};
    return _tail;
  }
  Future<void> _refresh(EncryptedSegmentCodec codec) async {
    if (codec.vaultPublicId != policy.membership.state.vaultPublicId) {
      throw StateError('目录Vault不匹配');
    }
    final epoch = policy.membership.state.epoch;
    final frozen = _freeze();
    for (final bytes in frozen.values) {
      await codec.decode(Segment.decode(bytes));
      if (!_accepting) throw StateError('可信目录已停止');
    }
    if (!_accepting || epoch != policy.membership.state.epoch) throw StateError('目录授权已改变');
    final latest = _freeze();
    if (latest.length != frozen.length || !frozen.entries.every((entry) =>
        const ListEquality<int>().equals(entry.value, latest[entry.key]))) {
      throw StateError('目录发布版本已改变，请重试');
    }
    _epoch = epoch;
    _files = Map<String, List<int>>.unmodifiable(frozen);
  }
  bool _allowed() => policy.checkLocalPublication(keyEpoch: policy.membership.state.epoch).isAllowed;
  bool _enabled() {
    final row = _db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
    return row['device_id'] == deviceId && row['enabled'] == 1 &&
        row['baseline_ready'] == 1 && row['requires_new_identity'] == 0;
  }
  Map<String, List<int>> _freeze() {
    if (!_db.raw.autocommit) throw StateError('不能暴露未提交的目录');
    return _db.transaction(() {
      if (!_enabled() || !_allowed()) return <String, List<int>>{};
      final epoch = policy.membership.state.epoch;
      final size = _db.raw.select('SELECT COUNT(*) AS n,COALESCE(SUM(length(segment_bytes)),0) AS bytes '
          'FROM sync_publications WHERE published=1 AND '
          '(key_epoch=? OR (key_epoch<? AND sealed=1))', [epoch, epoch]).single;
      if ((size['n'] as int) > maxFiles || (size['bytes'] as int) > maxCatalogBytes) {
        throw StateError('可信目录已达容量上限');
      }
      final files = <String, List<int>>{};
      for (final row in _db.raw.select('SELECT * FROM sync_publications '
          'WHERE published=1 AND (key_epoch=? OR (key_epoch<? AND sealed=1)) '
          'ORDER BY seq', [epoch, epoch])) {
        final bytes = List<int>.unmodifiable(row['segment_bytes'] as List<int>);
        if (bytes.length > VaultStore.maxSegmentFileBytes) throw StateError('发布文件过大');
        final segment = Segment.decode(bytes);
        final name = VaultLayout.segmentName(segment.createdAt.year, segment.createdAt.month, segment.seq);
        if (segment.deviceId != deviceId || segment.seq != row['seq'] ||
            segment.keyEpoch != row['key_epoch'] || segment.sealed != (row['sealed'] == 1) ||
            (segment.keyEpoch != epoch && (!segment.isSealed || segment.keyEpoch >= epoch)) ||
            segment.signature.length != 64 || segment.payload.length < 40 ||
            !segment.createdAt.isUtc || segment.opCount < 1 || segment.opCount > 500 ||
            name != row['file_name']) {
          throw StateError('发布记录不一致');
        }
        files['ops/$deviceId/$name'] = bytes;
      }
      return files;
    });
  }
}
