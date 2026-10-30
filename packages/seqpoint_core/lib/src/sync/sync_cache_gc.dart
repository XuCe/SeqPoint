import 'dart:convert';
import 'dart:io';
import '../db/database.dart';
import 'sync_files.dart';
import 'sync_manifest.dart';
import 'transport/lan_protocol.dart';

Map<String,Object?> _header(List<int> bytes,String hash) {
  if(bytes.length>SyncManifestCodec.maxBytes || lanSha256(bytes)!=hash) {
    throw const FormatException('Invalid cached manifest');
  }
  final envelope=jsonDecode(utf8.decode(bytes)) as Map;
  final header=Map<String,Object?>.from(jsonDecode(utf8.decode(
    base64Url.decode(base64Url.normalize(envelope['payload'] as String)))) as Map);
  if(!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(header['writer'] as String) ||
      (header['chunks'] as List).any((v)=>v is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(v))) {
    throw const FormatException('Invalid cached chunk reference');
  }
  return header;
}

String _roots(SeqDatabase db)=>jsonEncode([
  db.raw.select('SELECT manifest_hash FROM sync_checkpoints ORDER BY author').map((r)=>r['manifest_hash']).toList(),
  db.raw.select('SELECT manifest_hash FROM attachments WHERE manifest_hash IS NOT NULL ORDER BY id').map((r)=>r['manifest_hash']).toList(),
]);

/// Only encrypted cache is reclaimed; originals and recoverable media stay intact.
Future<int> collectSyncCache(SeqDatabase db,SyncFiles files,{DateTime? now}) async {
  final cutoff=(now??DateTime.now()).subtract(const Duration(hours:24));
  final roots=_roots(db),live=<String>{},remove=<String>[];
  final requiredHashes=(jsonDecode(roots) as List).expand((v)=>v as List).toSet();
  final foundHashes=<String>{};
  final manifests=files.file('manifests/placeholder').parent;
  if(!manifests.existsSync()) return 0;
  try {
    await for(final entry in manifests.list(recursive:true,followLinks:false)) {
      if(entry is! File || !entry.path.endsWith('.json')) continue;
      final relative=entry.path.substring(files.root.path.length+1);
      final hash=relative.split('/').last.replaceFirst('.json','');
      final header=_header(await files.read(relative,limit:SyncManifestCodec.maxBytes),hash);
      foundHashes.add(hash);
      if(requiredHashes.contains(hash) || header['kind']=='media' || !entry.lastModifiedSync().isBefore(cutoff)) {
        for(final chunk in header['chunks'] as List) {live.add('blobs/${header['writer']}/$chunk.bin');}
      } else if(header['kind']=='checkpoint') {remove.add(relative);}
      else {return 0;}
    }
  } on FormatException {return 0;}
  // An incomplete download may already reference older cached chunks.
  if(!foundHashes.containsAll(requiredHashes)) return 0;
  final blobs=files.file('blobs/placeholder').parent;
  if(blobs.existsSync()) {
    await for(final entry in blobs.list(recursive:true,followLinks:false)) {
      if(entry is! File || !entry.path.endsWith('.bin') || !entry.lastModifiedSync().isBefore(cutoff)) continue;
      final relative=entry.path.substring(files.root.path.length+1);
      if(!live.contains(relative)) remove.add(relative);
    }
  }
  var count=0;
  for(final relative in remove) {
    files.guard?.call();
    if(_roots(db)!=roots) break;
    final target=files.file(relative);
    if(target.existsSync()) {target.deleteSync();count++;}
  }
  return count;
}
