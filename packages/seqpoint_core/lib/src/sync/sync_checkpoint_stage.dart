import 'dart:convert';
import '../db/database.dart';
import 'operation.dart';
import 'operation_validation.dart';
import 'sync_manifest.dart';
import 'sync_blob_store.dart';

Future<void> stageSyncCheckpoint(SeqDatabase db,SyncManifest manifest,SyncBlobStore blobs) async {
  // The runtime admits one importer at a time. Uncommitted parsed rows are
  // disposable; resumable encrypted chunks remain in the content cache.
  db.raw.execute('DELETE FROM sync_checkpoint_staging');
  final line=<int>[];
  for(final chunk in manifest.chunks) {
    final bytes=await blobs.decode(chunk); blobs.files.guard?.call();
    if(!db.raw.autocommit) throw StateError('Checkpoint staging needs independent transaction');
    db.transaction(() {
      var offset=0;
      while(offset<bytes.length) {
        final newline=bytes.indexOf(10,offset), end=newline<0?bytes.length:newline;
        if(line.length+end-offset>12*1024*1024) throw const FormatException('Checkpoint record too large');
        line.addAll(bytes.sublist(offset,end)); offset=end+1;
        if(newline<0) break;
        final record=jsonDecode(utf8.decode(line)) as Map; line.clear();
        final sequence=record['seq'];
        final op=Operation.fromJson(Map<String,dynamic>.from(record['op'] as Map));
        validateIncomingOperation(op,expectedDeviceId:manifest.author);
        if(sequence is! int || sequence<1 || sequence>manifest.sequence) {
          throw const FormatException('Checkpoint fact outside covered prefix');
        }
        db.raw.execute('INSERT INTO sync_checkpoint_staging VALUES (?,?,?,?)',
          [manifest.hash,op.opId,sequence,jsonEncode(op.toJson())]);
      }
    });
  }
  if(line.isNotEmpty) throw const FormatException('Incomplete checkpoint record');
}
