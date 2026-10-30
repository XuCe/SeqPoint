import 'sync_checkpoint_proof.dart';
import 'sync_manifest.dart';

Future<void> verifySyncCheckpoint(SyncManifest manifest,SyncManifestCodec codec,
    Map<String,List<int>> authorKeys) async {
  final publicKey=authorKeys[manifest.author];
  if(manifest.kind!='checkpoint' || manifest.subject!=manifest.author || manifest.sequence<1 ||
      manifest.epoch!=codec.epoch || manifest.membershipHash!=codec.membershipHash || publicKey==null) {
    throw const FormatException('Checkpoint authorization context mismatch');
  }
  await verifyCheckpointProof(Map<String,Object?>.from(manifest.details['proof'] as Map),
    author:manifest.author,publicKey:publicKey,vault:codec.blobs.vaultId,
    sequence:manifest.sequence,anchor:manifest.anchor,chunks:manifest.chunks);
  codec.blobs.files.guard?.call();
}

/// Only an already verified durable local checkpoint may be transported for another author.
Future<SyncManifest> rewrapSyncCheckpoint(SyncManifest old,SyncManifestCodec codec) async {
  if(old.epoch==codec.epoch && old.membershipHash==codec.membershipHash &&
      codec.signers.containsKey(old.writer)) { return old; }
  final chunks=old.chunks.toList();
  // Sequential to bound crypto memory and preserve original plaintext ordering.
  for(var i=0;i<chunks.length;i++) {
    chunks[i]=await codec.blobs.encode(await codec.blobs.decode(chunks[i]),epoch:codec.epoch);
  }
  return codec.create(kind:'checkpoint',id:old.author,author:old.author,
    sequence:old.sequence,anchor:old.anchor,details:old.details,chunks:chunks);
}
