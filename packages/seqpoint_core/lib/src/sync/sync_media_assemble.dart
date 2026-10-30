import 'dart:io';
import 'package:cryptography/cryptography.dart';
import '../util/ids.dart';
import 'sync_blob_store.dart';
import 'sync_files.dart';
import 'sync_manifest.dart';

Future<void> assembleSyncMedia(SyncManifest manifest,SyncBlobStore blobs,
    SyncFiles originals,void Function() recheck) async {
  final target=originals.file(manifest.subject);
  await target.parent.create(recursive:true); originals.file(manifest.subject);
  final temporary=File('${target.path}.tmp.${newId()}');
  final output=await temporary.open(mode:FileMode.write);
  var closed=false,size=0;
  final digest=Sha256().newHashSink();
  try {
    for(final chunk in manifest.chunks) {
      final bytes=await blobs.decode(chunk);
      size+=bytes.length;
      if(size>(manifest.details['byte_size'] as int)) throw const FormatException('Media length exceeded');
      digest.add(bytes); await output.writeFrom(bytes);
    }
    digest.close();
    final hash=(await digest.hash()).bytes.map((v)=>v.toRadixString(16).padLeft(2,'0')).join();
    if(size!=manifest.details['byte_size'] || hash!=manifest.details['sha256']) {
      throw const FormatException('Original media hash mismatch');
    }
    await output.flush(); await output.close(); closed=true;
    recheck(); originals.file(manifest.subject); temporary.renameSync(target.path);
  } finally {
    if(!closed) await output.close();
    if(temporary.existsSync()) await temporary.delete();
  }
}
