import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'sync_blob_chunk.dart';
import 'sync_files.dart';
import 'sync_manifest.dart';
import 'sync_media_context.dart';
import '../db/database.dart';
import 'attachment_sync_policy.dart';

Future<void> prepareLocalSyncMedia(SeqDatabase db,SyncFiles originals,SyncManifestCodec codec) async {
  final policy=AttachmentSyncPolicy(db);
  if(!policy.enabled) return;
  final rows=db.raw.select("SELECT * FROM attachments WHERE sync<>'local_only' ORDER BY id");
  for(final row in rows) {
    codec.blobs.files.guard?.call();
    if(!policy.enabled) return;
    if(!originals.file(row['id'] as String).existsSync()) continue;
    if(row['content_owner']!=codec.keys.deviceId && await mediaContextCurrent(row,codec)) continue;
    final manifest=await prepareSyncMedia(row,originals,codec);codec.blobs.files.guard?.call();
    if(!policy.enabled) return;
    final latest=policy.sharedRow(row['id'] as String);
    if(latest==null || latest['sha256']!=row['sha256'] || latest['content_owner']!=row['content_owner']) continue;
    if(latest['manifest_hash']!=manifest.hash) {
      policy.capture(row['id'] as String,()=>db.raw.execute('UPDATE attachments SET content_owner=?,manifest_hash=? WHERE id=?',[codec.keys.deviceId,manifest.hash,row['id']]));
    }
  }
}

Future<SyncManifest> prepareSyncMedia(Map<String,Object?> row,
    SyncFiles originals, SyncManifestCodec codec) async {
  final id=row['id'] as String,hash=row['sha256'] as String;
  final cache='cache/media-$id-$hash-${codec.epoch}-${codec.membershipHash}.json';
  final files=codec.blobs.files;
  if(files.file(cache).existsSync()) {
    try {
      final digest=utf8.decode(await files.read(cache,limit:64));
      final manifest=await codec.open(await files.read('manifests/${codec.keys.deviceId}/$digest.json',
        limit:SyncManifestCodec.maxBytes),expectedHash:digest);
      var complete=true;
      for(final chunk in manifest.chunks) {
        if(!files.file(chunk.path).existsSync()) {complete=false;break;}
        await codec.blobs.frame(chunk);
      }
      if(complete) return manifest;
    } on FormatException {
      files.file(cache).deleteSync();
    }
  }
  final source=await originals.file(id).open(mode:FileMode.read);
  final digest=Sha256().newHashSink(), chunks=<SyncBlobChunk>[];
  var size=0;
  try {
    while(true) {
      final bytes=await source.read(SyncBlobChunk.maxPlainSize);
      if(bytes.isEmpty) break;
      originals.file(id); size+=bytes.length;
      if(size>(row['byte_size'] as int)) throw const FormatException('Original file size changed');
      digest.add(bytes); chunks.add(await codec.blobs.encode(bytes,epoch:codec.epoch));
    }
  } finally { await source.close(); }
  digest.close();
  final computed=(await digest.hash()).bytes.map((v)=>v.toRadixString(16).padLeft(2,'0')).join();
  if(size!=row['byte_size'] || computed!=hash) throw const FormatException('Original file hash changed');
  final manifest=await codec.create(kind:'media',id:id,details:{'sha256':hash,'byte_size':size},chunks:chunks);
  await files.write(cache,utf8.encode(manifest.hash)); return manifest;
}
