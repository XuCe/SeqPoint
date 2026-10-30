import '../db/database.dart';
import 'attachment_sync_policy.dart';
import 'sync_manifest.dart';
import 'sync_media_context.dart';
import 'transport/lan_protocol.dart';
import 'transport/published_file_view.dart';

Future<PublishedFileView> syncContentCatalog(SeqDatabase db,SyncManifestCodec codec) async {
  final entries=<String,PublishedEntry>{},provider=codec.keys.deviceId,files=codec.blobs.files;
  void add(SyncManifest manifest,{required bool media}) {
    void guard() {
      files.guard?.call();
      if(media && !AttachmentSyncPolicy(db).enabled) throw StateError('Media serving paused');
    }
    final alias=media?'content/$provider/${manifest.hash}.json':'checkpoints/$provider/${manifest.author}.json';
    entries[alias]=(size:manifest.bytes.length,read:(){guard();return manifest.bytes;});
    for(final chunk in manifest.chunks) {
      if(!files.file(chunk.path).existsSync()) continue;
      entries['content/$provider/${chunk.hash}.bin']=(size:chunk.size,read:(){
        guard();final file=files.file(chunk.path);
        if(file.lengthSync()!=chunk.size) throw StateError('Published content size changed');
        final bytes=file.readAsBytesSync();
        if(lanSha256(bytes)!=chunk.hash) throw StateError('Published content hash changed');
        return bytes;
      });
    }
  }
  for(final row in db.raw.select('SELECT manifest_bytes,manifest_hash FROM sync_checkpoints')) {
    final manifest=await codec.open(row['manifest_bytes'] as List<int>,expectedHash:row['manifest_hash'] as String);
    if(manifest.epoch==codec.epoch && manifest.membershipHash==codec.membershipHash) add(manifest,media:false);
  }
  if(AttachmentSyncPolicy(db).enabled) {
    for(final row in db.raw.select("SELECT DISTINCT content_owner,manifest_hash FROM attachments WHERE sync<>'local_only' AND manifest_hash IS NOT NULL")) {
      if(!await mediaContextCurrent(row,codec)) continue;
      final path='manifests/${row['content_owner']}/${row['manifest_hash']}.json';
      if(!files.file(path).existsSync()) continue;
      final manifest=await codec.open(await files.read(path,limit:SyncManifestCodec.maxBytes),expectedHash:row['manifest_hash'] as String);
      add(manifest,media:true);
    }
  }
  files.guard?.call();return PublishedFileView(entries);
}
