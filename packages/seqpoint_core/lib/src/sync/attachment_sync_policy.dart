import '../db/database.dart';
import 'sync_outbox.dart';

/// A local opt-in. Revoking transport cannot retract an already shared copy.
class AttachmentSyncPolicy {
  AttachmentSyncPolicy(this.db);
  final SeqDatabase db;
  bool get enabled => db.raw.select('SELECT media_enabled FROM sync_local WHERE id=1').single['media_enabled'] == 1;
  Map<String, Object?>? sharedRow(String id) {
    final rows = db.raw.select("SELECT * FROM attachments WHERE id=? AND sync<>'local_only'", [id]);
    return rows.isEmpty ? null : rows.single;
  }
  T capture<T>(String id, T Function() write) => SyncOutbox(db).capture(
    'attachment', id, read: () => sharedRow(id), write: write);

  void setEnabled(bool value, {bool includeExisting = true}) => db.transaction(() {
    final local = db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
    if (local['enabled'] != 1 || local['requires_new_identity'] != 0 || local['device_id'] == null) {
      throw StateError('请先完成同步空间配置');
    }
    db.raw.execute('UPDATE sync_local SET media_enabled=? WHERE id=1', [value ? 1 : 0]);
    if (!value || !includeExisting) return;
    final ids = db.raw.select("SELECT id FROM attachments WHERE sync='local_only' ORDER BY id");
    for (final row in ids) {
      final id = row['id'] as String;
      capture(id, () => db.raw.execute("UPDATE attachments SET sync='trusted_devices',content_owner=? WHERE id=?",
        [local['device_id'], id]));
    }
  });
}
