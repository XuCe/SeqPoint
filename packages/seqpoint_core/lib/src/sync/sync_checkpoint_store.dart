import '../db/database.dart';
import 'sync_checkpoint_facts.dart';
import 'sync_manifest.dart';

void storeSyncCheckpoint(SeqDatabase db,SyncManifest manifest,{required int floor}) {
  final prior=db.raw.select('SELECT covered_seq,local_floor,anchor FROM sync_checkpoints WHERE author=?',[manifest.author]);
  if(prior.isNotEmpty && ((prior.single['covered_seq'] as int)>manifest.sequence ||
      (prior.single['covered_seq']==manifest.sequence && prior.single['anchor']!=manifest.anchor) ||
      (prior.single['local_floor'] as int)>floor)) {
    throw StateError('Checkpoint rollback or fork');
  }
  db.raw.execute('INSERT INTO sync_checkpoints '
    '(author,covered_seq,anchor,writer,manifest_hash,manifest_bytes,key_epoch,local_floor) VALUES (?,?,?,?,?,?,?,?) '
    'ON CONFLICT(author) DO UPDATE SET covered_seq=excluded.covered_seq,anchor=excluded.anchor,'
    'writer=excluded.writer,manifest_hash=excluded.manifest_hash,manifest_bytes=excluded.manifest_bytes,'
    'key_epoch=excluded.key_epoch,local_floor=excluded.local_floor',
    [manifest.author,manifest.sequence,manifest.anchor,manifest.writer,manifest.hash,manifest.bytes,manifest.epoch,floor]);
}

void pruneCheckpointFacts(SeqDatabase db,String author,int floor) {
  db.raw.execute('DELETE FROM sync_operations WHERE device_id=? AND publication_seq<=? '
    'AND op_id NOT IN (SELECT op_id FROM ($checkpointWinnerSql))',[author,floor,author,floor]);
  db.raw.execute('DELETE FROM sync_received_segments WHERE device_id=? AND seq<=?',[author,floor]);
}
