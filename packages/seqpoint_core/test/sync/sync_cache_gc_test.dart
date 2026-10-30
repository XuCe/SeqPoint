import 'dart:io';
import 'package:seqpoint_core/src/sync/sync_blob_store.dart';
import 'package:seqpoint_core/src/sync/sync_manifest.dart';
import 'package:seqpoint_core/src/sync/sync_checkpoint_store.dart';
import 'package:seqpoint_core/src/sync/sync_cache_gc.dart';
import 'package:test/test.dart';
import 'lan_sync_runtime_fixture.dart';

void main() {
  test('cache GC preserves roots, recoverable media and in-flight grace',() async {
    final f=RuntimeFixture();await f.init(vaultId:'v'*43);addTearDown(f.dispose);
    final a=f.a,state=a.membership.state;
    final codec=SyncManifestCodec(blobs:SyncBlobStore(root:Directory('${a.directory.path}/vault'),
      vaultId:state.vaultPublicId,deviceId:a.keys.deviceId,epochKeys:{state.epoch:a.epochKey.keyBytes}),
      keys:a.keys,epoch:state.epoch,membershipHash:state.headHash,
      signers:{a.keys.deviceId:a.keys.signer.publicKey});
    Future<SyncManifest> create(String kind,int seq) async=>codec.create(kind:kind,id:'test',
      sequence:kind=='checkpoint'?seq:0,details:{},
      chunks:[await codec.blobs.encode(List.filled(256,seq),epoch:state.epoch)]);
    final obsolete=await create('checkpoint',1),current=await create('checkpoint',2);
    final media=await create('media',3),pending=await create('checkpoint',4);
    storeSyncCheckpoint(a.db,current,floor:0);
    final old=DateTime.now().subtract(const Duration(days:2)),files=codec.blobs.files;
    for(final manifest in [obsolete,current,media,pending]) {
      for(final chunk in manifest.chunks) {await files.file(chunk.path).setLastModified(old);}
      if(manifest!=pending) await files.file(manifest.path).setLastModified(old);
    }
    expect(await collectSyncCache(a.db,files),2);
    expect(files.file(obsolete.path).existsSync(),isFalse);
    expect(files.file(obsolete.chunks.single.path).existsSync(),isFalse);
    for(final manifest in [current,media,pending]) {
      expect(files.file(manifest.path).existsSync(),isTrue);
      expect(files.file(manifest.chunks.single.path).existsSync(),isTrue);
    }
    // Missing root manifests make deletion unsafe, even if candidate chunks are old.
    final orphan=await codec.blobs.encode(List.filled(256,5),epoch:state.epoch);
    await files.file(orphan.path).setLastModified(old);
    await files.file(current.path).delete();
    expect(await collectSyncCache(a.db,files),0);
    expect(files.file(orphan.path).existsSync(),isTrue);
  });
}
