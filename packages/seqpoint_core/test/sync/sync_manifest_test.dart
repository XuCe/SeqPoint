import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/sync/sync_blob_store.dart';
import 'package:seqpoint_core/src/sync/sync_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('signed encrypted manifest is immutable, cached and bound to vault/version', () async {
    final root=await Directory.systemTemp.createTemp('sync-manifest-');
    addTearDown(()=>root.delete(recursive:true));
    final keys=await DeviceKeys.fromSeeds(List.filled(32,1),List.filled(32,2));
    SyncBlobStore blobs(String vault)=>SyncBlobStore(root:root,vaultId:vault,
      deviceId:keys.deviceId,epochKeys:{1:List.filled(32,7)});
    SyncManifestCodec codec(String vault)=>SyncManifestCodec(blobs:blobs(vault),keys:keys,
      epoch:1,membershipHash:'m'*43,signers:{keys.deviceId:keys.signer.publicKey});
    final chunk=await blobs('v'*43).encode([1,2,3],epoch:1);
    Future<SyncManifest> create()=>codec('v'*43).create(kind:'media',id:'file',
      details:{'byte_size':3,'sha256':'plain-hash'},chunks:[chunk]);
    final manifest=await create();
    expect((await create()).hash,manifest.hash);
    final opened=await codec('v'*43).open(manifest.bytes,expectedHash:manifest.hash);
    expect(opened.chunks.single.hash,chunk.hash);
    expect(opened.details['byte_size'],3);
    await expectLater(codec('w'*43).open(manifest.bytes,expectedHash:manifest.hash),throwsA(anything));
    await expectLater(codec('v'*43).open(manifest.bytes,expectedHash:'f'*64),throwsA(anything));
    final broken=List<int>.of(manifest.bytes); broken[broken.length~/2]^=1;
    await expectLater(codec('v'*43).open(broken,expectedHash:manifest.hash),throwsA(anything));
  });
}
