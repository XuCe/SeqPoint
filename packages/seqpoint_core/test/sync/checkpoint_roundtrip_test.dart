import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/sync/sync_blob_store.dart';
import 'package:seqpoint_core/src/sync/sync_manifest.dart';
import 'package:seqpoint_core/src/sync/sync_checkpoint_build.dart';
import 'package:seqpoint_core/src/sync/sync_checkpoint_verify.dart';
import 'package:seqpoint_core/src/sync/sync_checkpoint_stage.dart';
import 'package:seqpoint_core/src/sync/sync_checkpoint_commit.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';
import 'package:test/test.dart';
import 'lan_sync_runtime_fixture.dart';

void main() {
  test('sealed author checkpoint preserves versions and resumes later operations',() async {
    final f=RuntimeFixture();await f.init(vaultId:'v'*43);addTearDown(f.dispose);
    final a=f.a,b=f.b,state=a.membership.state,now=DateTime.now().toUtc();
    final repo=NoteRepository(a.db);
    repo.insert(Note(id:'n',kind:NoteKind.text,status:NoteStatus.active,rawContent:'0',createdAt:now,updatedAt:now));
    for(var i=1;i<=20;i++) {repo.update(repo.byId('n')!.copyWith(rawContent:'$i'));}
    final keys={a.keys.deviceId:a.keys.signer.publicKey,b.keys.deviceId:b.keys.signer.publicKey};
    final root=Directory('${a.directory.path}/vault'),epochs={state.epoch:a.epochKey.keyBytes};
    final segmentCodec=EncryptedSegmentCodec(vaultPublicId:state.vaultPublicId,deviceKeys:a.keys,epochKeys:epochs,trustedSigners:keys);
    final store=VaultStore(root:root,deviceId:a.keys.deviceId,codec:segmentCodec);
    final publisher=SyncPublisher(a.db,deviceId:a.keys.deviceId);
    while(await publisher.publishNext(store:store,keyEpoch:state.epoch)!=null) {}
    final head=(await publisher.sealHead(store:store))!;expect(head.sealed,isTrue);
    final codec=SyncManifestCodec(blobs:SyncBlobStore(root:root,vaultId:state.vaultPublicId,
      deviceId:a.keys.deviceId,epochKeys:epochs),keys:a.keys,epoch:state.epoch,membershipHash:state.headHash,signers:keys);
    final checkpoint=await buildSyncCheckpoint(a.db,codec,head.seq,lanSha256(head.bytes));
    await verifySyncCheckpoint(checkpoint,codec,keys);
    b.db.raw.execute('INSERT INTO sync_checkpoint_staging VALUES (?,?,?,?)',['abandoned','old',1,'{}']);
    await stageSyncCheckpoint(b.db,checkpoint,codec.blobs);
    expect(b.db.raw.select('SELECT 1 FROM sync_checkpoint_staging WHERE manifest_hash=?',['abandoned']),isEmpty);
    final before=a.db.raw.select('SELECT COUNT(*) AS n FROM sync_operations').single['n'] as int;
    final added=commitSyncCheckpoint(b.db,checkpoint,(){}); expect(added,lessThan(before));
    expect(NoteRepository(b.db).byId('n')!.rawContent,'20');
    expect(SyncSegmentReceiver(b.db).committedWatermarks[a.keys.deviceId],head.seq);
    final rotated=SyncManifestCodec(blobs:SyncBlobStore(root:root,vaultId:state.vaultPublicId,
      deviceId:b.keys.deviceId,epochKeys:{...epochs,state.epoch+1:List.filled(32,77)}),keys:b.keys,
      epoch:state.epoch+1,membershipHash:'m'*43,signers:{b.keys.deviceId:b.keys.signer.publicKey});
    final rewrapped=await rewrapSyncCheckpoint(checkpoint,rotated);
    expect(rewrapped.author,a.keys.deviceId);expect(rewrapped.writer,b.keys.deviceId);
    expect(rewrapped.details['proof'],checkpoint.details['proof']);
    await verifySyncCheckpoint(rewrapped,rotated,keys);
    await stageSyncCheckpoint(b.db,rewrapped,rotated.blobs);
    expect(commitSyncCheckpoint(b.db,rewrapped,(){}),0);
    repo.update(repo.byId('n')!.copyWith(rawContent:'later'));
    final next=(await publisher.publishNext(store:store,keyEpoch:state.epoch))!;
    expect(next.seq,head.seq+1);
    final segment=Segment.decode(next.bytes);
    await SyncSegmentReceiver(b.db).apply((segment:segment,bytes:next.bytes,operations:await segmentCodec.decode(segment)));
    expect(NoteRepository(b.db).byId('n')!.rawContent,'later');
  });
}
