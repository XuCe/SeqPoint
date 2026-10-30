import 'dart:convert';
import '../db/database.dart';
import 'operation.dart';
import 'sync_inbox.dart';
import 'sync_projector.dart';
import 'sync_checkpoint_store.dart';
import 'sync_manifest.dart';

int commitSyncCheckpoint(SeqDatabase db,SyncManifest manifest,void Function() guard) {
  if(!db.raw.autocommit) throw StateError('Checkpoint commit needs independent transaction');
  guard();
  return db.transaction(() {
    final local=db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
    if(local['enabled']!=1 || local['requires_new_identity']!=0 || local['device_id']==manifest.author) {
      throw StateError('Checkpoint receiver identity changed');
    }
    var added=0,last='';
    while(true) {
      final rows=db.raw.select('SELECT * FROM sync_checkpoint_staging WHERE manifest_hash=? AND op_id>? ORDER BY op_id LIMIT 500',
        [manifest.hash,last]);
      if(rows.isEmpty) break;
      final ops=rows.map((r)=>Operation.fromJson(Map<String,dynamic>.from(jsonDecode(r['operation_json'] as String) as Map))).toList();
      added+=SyncInbox(db).storeVerifiedBatch(peerId:manifest.author,operations:ops);
      for(final row in rows) {
        final existing=db.raw.select('SELECT publication_seq FROM sync_operations WHERE op_id=?',[row['op_id']]).single;
        if(existing['publication_seq']!=null && existing['publication_seq']!=row['publication_seq']) {
          throw const FormatException('Checkpoint changed operation ownership');
        }
        db.raw.execute('UPDATE sync_operations SET publication_seq=? WHERE op_id=?',[row['publication_seq'],row['op_id']]);
      }
      last=rows.last['op_id'] as String;
    }
    storeSyncCheckpoint(db,manifest,floor:manifest.sequence);
    db.raw.execute('INSERT INTO sync_state(device_id,applied_seq) VALUES (?,?) '
      'ON CONFLICT(device_id) DO UPDATE SET applied_seq=MAX(applied_seq,excluded.applied_seq)',[manifest.author,manifest.sequence]);
    pruneCheckpointFacts(db,manifest.author,manifest.sequence);
    SyncProjector(db).project();
    db.raw.execute('DELETE FROM sync_checkpoint_staging WHERE manifest_hash=?',[manifest.hash]);
    return added;
  });
}
