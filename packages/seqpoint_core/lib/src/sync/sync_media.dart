import 'dart:io';
import '../db/database.dart';
import 'attachment_sync_policy.dart';
import 'sync_content_transfer.dart';
import 'sync_files.dart';
import 'sync_media_prepare.dart';
import 'sync_media_context.dart';
import 'sync_media_assemble.dart';

class SyncMedia {
  SyncMedia(this.db,this.transfer,Directory directory)
    : originals=SyncFiles(directory,guard:transfer.codec.blobs.files.guard);
  final SeqDatabase db;
  final SyncContentTransfer transfer;
  final SyncFiles originals;
  bool get enabled=>AttachmentSyncPolicy(db).enabled;
  int completed=0;
  bool pending=false;
  void check() {
    transfer.codec.blobs.files.guard?.call();
    if(!enabled) throw StateError('Original file sync paused');
  }
  Future<void> push() async {
    if(!enabled) return;
    final rows=db.raw.select("SELECT * FROM attachments WHERE sync<>'local_only' ORDER BY id");
    await transfer.checkUploadedManifests([
      for(final row in rows) if(row['manifest_hash']!=null)
        'manifests/${row['content_owner']}/${row['manifest_hash']}.json',
    ]);
    for(final row in rows) {
      check(); if(!originals.file(row['id'] as String).existsSync()) continue;
      if(row['content_owner']!=transfer.codec.keys.deviceId && await mediaContextCurrent(row,transfer.codec)) continue;
      if(transfer.budget.exhausted) {pending=true;return;}
      final manifest=await prepareSyncMedia(row,originals,transfer.codec);
      if(!await transfer.upload(manifest)) {pending=true;return;}
      check();
      final latest=AttachmentSyncPolicy(db).sharedRow(row['id'] as String);
      if(latest==null || latest['sha256']!=row['sha256'] || latest['content_owner']!=row['content_owner']) continue;
      if(latest['manifest_hash']!=manifest.hash) {
        AttachmentSyncPolicy(db).capture(row['id'] as String,()=>db.raw.execute(
          'UPDATE attachments SET content_owner=?,manifest_hash=? WHERE id=?',[transfer.codec.keys.deviceId,manifest.hash,row['id']]));
      }
    }
  }
  Future<void> pull() async {
    if(!enabled) return;
    final rows=db.raw.select("SELECT * FROM attachments WHERE sync<>'local_only' AND manifest_hash IS NOT NULL AND deleted_at IS NULL ORDER BY id");
    for(final row in rows) {
      check();
      final id=row['id'] as String, hash=row['manifest_hash'] as String;
      final owner=row['content_owner'] as String?;
      if(owner==null) continue;
      if(!transfer.codec.signers.containsKey(owner)) {pending=true;continue;}
      if(originals.file(id).existsSync() && originals.file(id).lengthSync()==row['byte_size']) continue;
      if(transfer.budget.exhausted) {pending=true;return;}
      final manifest=await transfer.manifest(owner,hash);
      if(manifest==null) {pending=true;continue;}
      if(manifest.kind!='media' || manifest.subject!=id || manifest.writer!=owner ||
          manifest.details['sha256']!=row['sha256'] || manifest.details['byte_size']!=row['byte_size'] ||
          manifest.chunks.fold<int>(0,(n,c)=>n+c.plainSize)!=row['byte_size']) {
        throw const FormatException('Media manifest does not match winning metadata');
      }
      if(!await transfer.download(manifest)) {pending=true;return;}
      await assembleSyncMedia(manifest,transfer.codec.blobs,originals,() {
        check(); final latest=AttachmentSyncPolicy(db).sharedRow(id);
        if(latest==null || latest['manifest_hash']!=hash || latest['deleted_at']!=null ||
            latest['sha256']!=row['sha256']) { throw StateError('Media version changed'); }
      });
      completed++;
    }
  }
}
