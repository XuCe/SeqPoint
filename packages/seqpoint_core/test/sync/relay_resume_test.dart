import 'dart:io';
import 'dart:math';
import 'package:seqpoint_core/src/sync/sync_blob_store.dart';
import 'package:seqpoint_core/src/sync/sync_content_transfer.dart';
import 'package:seqpoint_core/src/sync/sync_manifest.dart';
import 'package:test/test.dart';
import 'relay_node_fixture.dart';

void main() {
  test('byte budget resumes after restart without retransmitting uploaded chunks',() async {
    final f=RelayNodeFixture(); await f.init(); addTearDown(f.close);
    final a=f.runtime.a,state=a.membership.state;
    final codec=SyncManifestCodec(blobs:SyncBlobStore(root:Directory('${a.directory.path}/vault'),
      vaultId:state.vaultPublicId,deviceId:a.keys.deviceId,epochKeys:{state.epoch:a.epochKey.keyBytes}),
      keys:a.keys,epoch:state.epoch,membershipHash:state.headHash,
      signers:{a.keys.deviceId:a.keys.signer.publicKey});
    final random=Random(42);
    final chunks=[for(var i=0;i<3;i++) await codec.blobs.encode(
      List.generate(1024*1024,(_)=>random.nextInt(256)),epoch:state.epoch)];
    final manifest=await codec.create(kind:'media',id:'resume',details:{},chunks:chunks);
    final firstClient=f.client(a),first=SyncTransferBudget(remaining:2*1024*1024,bytesPerSecond:0);
    expect(await SyncContentTransfer(codec,firstClient,first).upload(manifest),isFalse);
    firstClient.close(); expect(first.transferred,chunks.first.size);
    await f.stop(); await f.start();
    final secondClient=f.client(a),second=SyncTransferBudget(bytesPerSecond:0);
    expect(await SyncContentTransfer(codec,secondClient,second).upload(manifest),isTrue);
    secondClient.close();
    expect(second.transferred,chunks[1].size+chunks[2].size+manifest.bytes.length);
    final thirdClient=f.client(a),third=SyncTransferBudget(bytesPerSecond:0);
    expect(await SyncContentTransfer(codec,thirdClient,third).upload(manifest),isTrue);
    thirdClient.close(); expect(third.transferred,0);
    final remoteChunk=(await Directory('${f.directory.path}/data').list(recursive:true).toList())
      .whereType<File>().singleWhere((file)=>file.path.endsWith(chunks.first.path));
    await remoteChunk.delete();
    final cachedClient=f.client(a),cachedBudget=SyncTransferBudget(bytesPerSecond:0);
    final cached=SyncContentTransfer(codec,cachedClient,cachedBudget);
    await cached.checkUploadedManifests([manifest.path]);
    expect(await cached.upload(manifest),isTrue);
    expect(cachedBudget.transferred,0); // Cheap minute-level check, full hourly audit below.
    cachedClient.close();
    await codec.blobs.files.file('cache/upload-audit-${manifest.hash}')
      .setLastModified(DateTime.now().subtract(const Duration(hours:2)));
    final auditClient=f.client(a),auditBudget=SyncTransferBudget(bytesPerSecond:0);
    final audit=SyncContentTransfer(codec,auditClient,auditBudget);
    await audit.checkUploadedManifests([manifest.path]);
    expect(await audit.upload(manifest),isTrue);
    expect(auditBudget.transferred,chunks.first.size);
    auditClient.close();
    final newRoot=Directory('${a.directory.path}/new-member-cache');
    final noOldKey=SyncManifestCodec(blobs:SyncBlobStore(root:newRoot,vaultId:state.vaultPublicId,
      deviceId:a.keys.deviceId,epochKeys:{2:List.filled(32,44)}),keys:a.keys,epoch:2,
      membershipHash:state.headHash,signers:{a.keys.deviceId:a.keys.signer.publicKey});
    final waitingClient=f.client(a),waitingBudget=SyncTransferBudget(bytesPerSecond:0);
    final waiting=SyncContentTransfer(noOldKey,waitingClient,waitingBudget);
    expect(await waiting.manifest(a.keys.deviceId,manifest.hash),isNull);
    final firstRead=waitingBudget.transferred;
    expect(firstRead,manifest.bytes.length);
    expect(await waiting.manifest(a.keys.deviceId,manifest.hash),isNull);
    expect(waitingBudget.transferred,firstRead);
    waitingClient.close();
    final damaged=await codec.blobs.frame(chunks.first);
    damaged[damaged.length-1]^=1;
    await codec.blobs.files.file(chunks.first.path).writeAsBytes(damaged);
    final repairClient=f.client(a),repair=SyncTransferBudget(bytesPerSecond:0);
    expect(await SyncContentTransfer(codec,repairClient,repair).download(manifest),isTrue);
    repairClient.close();expect(repair.transferred,chunks.first.size);
    expect(await codec.blobs.decode(chunks.first),hasLength(1024*1024));
  },skip:Platform.environment['SEQPOINT_NODE_BINARY']==null?'Set node binary':false);
}
