import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';
import 'package:test/test.dart';
import 'publication_history_test.dart' show addPublication;

void main() {
  late SeqDatabase db;
  setUp(()=>db=SeqDatabase.inMemory()..migrate()); tearDown(()=>db.close());
  void checkpoint(String author,int sequence,int floor) {
    db.raw.execute('INSERT INTO sync_checkpoints '
      '(author,covered_seq,anchor,writer,manifest_hash,manifest_bytes,key_epoch,local_floor) '
      'VALUES (?,?,?,?,?,?,?,?)',[author,sequence,'a'*64,author,lanSha256([1,2,3]),[1,2,3],2,floor]);
  }
  test('publisher uses verified compaction floor but still rejects new gaps',() {
    SyncBaseline(db).initialize('writer');
    addPublication(db,3,sealed:true); checkpoint('writer',3,2);
    final publisher=SyncPublisher(db,deviceId:'writer');
    expect(publisher.freeze().head!.seq,3);
    addPublication(db,5); expect(()=>publisher.freeze(),throwsStateError);
  });
  test('receiver ACK uses durable checkpoint anchor and detects damaged proof',() {
    SyncBaseline(db).initialize('reader'); checkpoint('writer',1000,1000);
    db.raw.execute('INSERT INTO sync_state(device_id,applied_seq) VALUES (?,?)',['writer',1000]);
    final receiver=SyncSegmentReceiver(db);
    expect(receiver.committedWatermarks,{'writer':1000});
    db.raw.execute('UPDATE sync_checkpoints SET manifest_bytes=?',[[9]]);
    expect(()=>receiver.committedWatermarks,throwsStateError);
  });
  test('restore removes old checkpoint and staging authorization',() {
    checkpoint('writer',10,9);
    db.raw.execute('INSERT INTO sync_checkpoint_staging VALUES (?,?,?,?)',['hash','op',1,'{}']);
    db.disconnectSyncForRestore();
    expect(db.raw.select('SELECT * FROM sync_checkpoints'),isEmpty);
    expect(db.raw.select('SELECT * FROM sync_checkpoint_staging'),isEmpty);
  });
}
