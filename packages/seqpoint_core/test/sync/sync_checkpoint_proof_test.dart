import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/sync/sync_blob_store.dart';
import 'package:seqpoint_core/src/sync/sync_checkpoint_proof.dart';
import 'package:test/test.dart';

void main() {
  test('another device can reencrypt unchanged facts but cannot rewrite author proof', () async {
    final root=await Directory.systemTemp.createTemp('proof-rewrap-');
    addTearDown(()=>root.delete(recursive:true));
    final a=await DeviceKeys.fromSeeds(List.filled(32,1),List.filled(32,2));
    final b=await DeviceKeys.fromSeeds(List.filled(32,3),List.filled(32,4));
    SyncBlobStore store(DeviceKeys device,int epoch)=>SyncBlobStore(root:root,vaultId:'v'*43,
      deviceId:device.deviceId,epochKeys:{epoch:List.filled(32,epoch)});
    final original=await store(a,1).encode([1,2,3],epoch:1);
    final proof=await signCheckpointProof(keys:a,vault:'v'*43,sequence:10,anchor:'a'*64,
      membership:'m'*43,chunks:[original]);
    final wrapped=await store(b,2).encode([1,2,3],epoch:2);
    expect(wrapped.hash,isNot(original.hash));
    await verifyCheckpointProof(proof,author:a.deviceId,publicKey:a.signer.publicKey,
      vault:'v'*43,sequence:10,anchor:'a'*64,chunks:[wrapped]);
    final altered=await store(b,2).encode([1,2,4],epoch:2);
    await expectLater(verifyCheckpointProof(proof,author:a.deviceId,publicKey:a.signer.publicKey,
      vault:'v'*43,sequence:10,anchor:'a'*64,chunks:[altered]),throwsFormatException);
    await expectLater(verifyCheckpointProof(proof,author:b.deviceId,publicKey:b.signer.publicKey,
      vault:'v'*43,sequence:10,anchor:'a'*64,chunks:[wrapped]),throwsFormatException);
  });
}
