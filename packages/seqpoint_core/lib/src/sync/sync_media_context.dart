import 'dart:convert';
import 'sync_manifest.dart';
import 'transport/lan_protocol.dart';

/// Used only to decide whether a holder must re-publish; receiving still verifies signatures.
Future<bool> mediaContextCurrent(Map<String,Object?> row,SyncManifestCodec codec) async {
  final owner=row['content_owner'],hash=row['manifest_hash'];
  if(owner==null || hash==null || !codec.signers.containsKey(owner)) return false;
  final path='manifests/$owner/$hash.json',files=codec.blobs.files;
  if(!files.file(path).existsSync()) return false;
  try {
    final bytes=await files.read(path,limit:SyncManifestCodec.maxBytes);
    if(lanSha256(bytes)!=hash) return false;
    final envelope=jsonDecode(utf8.decode(bytes)) as Map;
    final header=jsonDecode(utf8.decode(base64Url.decode(
      base64Url.normalize(envelope['payload'] as String)))) as Map;
    return header['writer']==owner && header['epoch']==codec.epoch &&
      header['membership']==codec.membershipHash;
  } on FormatException {return false;}
    on TypeError {return false;}
}
