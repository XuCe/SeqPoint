import 'dart:convert';
import '../db/database.dart';
import 'operation_validation.dart';
import 'sync_blob_chunk.dart';
import 'sync_checkpoint_facts.dart';
import 'sync_checkpoint_proof.dart';
import 'sync_manifest.dart';

Future<SyncManifest> buildSyncCheckpoint(SeqDatabase db,SyncManifestCodec codec,
    int sequence,String anchor) async {
  final chunks=<SyncBlobChunk>[],buffer=<int>[];
  String? bucket;
  Future<void> flush() async {
    if(buffer.isEmpty) return;
    chunks.add(await codec.blobs.encode(buffer,epoch:codec.epoch)); buffer.clear();
  }
  for(final row in checkpointFacts(db,codec.keys.deviceId,sequence)) {
    codec.blobs.files.guard?.call();
    final op=checkpointOperation(row); validateIncomingOperation(op,expectedDeviceId:codec.keys.deviceId);
    final next=op.objectId.substring(0,op.objectId.length.clamp(0,2));
    if(next!=bucket) {await flush();bucket=next;}
    final bytes=utf8.encode('${jsonEncode({'seq':row['publication_seq'],'op':op.toJson()})}\n');
    for(var offset=0;offset<bytes.length;) {
      final count=(SyncBlobChunk.maxPlainSize-buffer.length).clamp(0,bytes.length-offset);
      buffer.addAll(bytes.sublist(offset,offset+count));offset+=count;
      if(buffer.length==SyncBlobChunk.maxPlainSize) await flush();
    }
  }
  await flush();
  final proof=await signCheckpointProof(keys:codec.keys,vault:codec.blobs.vaultId,
    sequence:sequence,anchor:anchor,membership:codec.membershipHash,chunks:chunks);
  return codec.create(kind:'checkpoint',id:codec.keys.deviceId,sequence:sequence,anchor:anchor,
    details:{'proof':proof},chunks:chunks);
}
