import 'dart:convert';
import 'dart:io';
import '../crypto/ed25519_signer.dart';
import '../crypto/xchacha20_aead.dart';
import '../identity/device_keys.dart';
import 'sync_blob_store.dart';
import 'sync_blob_codec.dart';
import 'sync_manifest_data.dart';
import 'sync_manifest_header.dart';
import 'transport/lan_protocol.dart';
export 'sync_manifest_data.dart';

class SyncManifestCodec {
  SyncManifestCodec({required this.blobs,required this.keys,required this.epoch,
    required this.membershipHash,required Map<String,List<int>> signers})
    :signers=Map.unmodifiable(signers.map((id,key)=>MapEntry(id,List<int>.unmodifiable(key))));
  final SyncBlobStore blobs;
  final DeviceKeys keys;
  final int epoch;
  final String membershipHash;
  final Map<String,List<int>> signers;
  static const maxBytes=12*1024*1024;
  Future<SyncManifest> create({required String kind,required String id,
    required Map<String,Object?> details,required List<SyncBlobChunk> chunks,
    String? author,int sequence=0,String? anchor}) async {
    if(chunks.any((c)=>c.owner!=keys.deviceId || c.epoch!=epoch)) { throw ArgumentError('Rewrap chunks before publishing'); }
    final meta=utf8.encode(jsonEncode({'details':details,'chunks':chunks.map((c)=>c.toJson()).toList()}));
    if(meta.length>8*1024*1024) { throw StateError('Manifest metadata exceeds file limit'); }
    final compressed=GZipCodec(level:6).encode(meta), metaHash=lanSha256(meta);
    final useGzip=compressed.length*100<=meta.length*95;
    final h=<String,Object?>{'version':2,'kind':kind,'vault':blobs.vaultId,'writer':keys.deviceId,
      'author':author??keys.deviceId,'epoch':epoch,'subject':id,'sequence':sequence,'anchor':anchor??'0'*64,
      'membership':membershipHash,'chunks':chunks.map((c)=>c.hash).toList(),
      'meta_codec':useGzip?'gzip':'raw','meta_size':meta.length,'meta_hash':metaHash};
    if(kind=='checkpoint') h['proof']=details['proof'];
    validateSyncManifestHeader(h,blobs.vaultId);
    final contextHash=lanSha256(utf8.encode(jsonEncode(h))), cache='cache/manifest-$contextHash.json';
    if(blobs.files.file(cache).existsSync()) {
      final hash=utf8.decode(await blobs.files.read(cache,limit:64));
      final path='manifests/${keys.deviceId}/$hash.json';
      if(blobs.files.file(path).existsSync()) {
        final old=await open(await blobs.files.read(path,limit:maxBytes),expectedHash:hash);
        if(old.contextHash!=contextHash) { throw const FormatException('Manifest cache mismatch'); }
        return old;
      }
    }
    final key=blobs.epochKeys[epoch];
    if(key==null) { throw StateError('Manifest epoch key unavailable'); }
    final frame=await XChaCha20Aead().seal(useGzip?compressed:meta,key,aad:syncManifestAad(h));
    h['data']=base64UrlEncode(frame).replaceAll('=', '');
    final payload=utf8.encode(jsonEncode(h));
    final signature=await keys.signer.sign(payload);
    blobs.files.guard?.call();
    final bytes=utf8.encode(jsonEncode({'payload':base64UrlEncode(payload).replaceAll('=', ''),
      'signature':base64UrlEncode(signature).replaceAll('=', '')}));
    final manifest=await open(bytes,expectedHash:lanSha256(bytes));
    await blobs.files.write(manifest.path,bytes);
    await blobs.files.write(cache,utf8.encode(manifest.hash));
    return manifest;
  }
  Future<SyncManifest> open(List<int> bytes,{required String expectedHash}) async {
    blobs.files.guard?.call();
    if(bytes.length>maxBytes || lanSha256(bytes)!=expectedHash) { throw const FormatException('Manifest hash mismatch'); }
    final envelope=jsonDecode(utf8.decode(bytes)) as Map;
    final payload=base64Url.decode(base64Url.normalize(envelope['payload'] as String));
    final h=Map<String,Object?>.from(jsonDecode(utf8.decode(payload)) as Map);
    validateSyncManifestHeader(h,blobs.vaultId);
    final signer=signers[h['writer']];
    final signature=base64Url.decode(base64Url.normalize(envelope['signature'] as String));
    if(signer==null || !await Ed25519Signer.verifyPublic(payload,signature,signer)) { throw const FormatException('Manifest signer unauthorized'); }
    blobs.files.guard?.call();
    final key=blobs.epochKeys[h['epoch']];
    if(key==null) { throw StateError('Manifest epoch key unavailable'); }
    final frame=base64Url.decode(base64Url.normalize(h['data'] as String));
    final packed=await XChaCha20Aead().open(frame,key,aad:syncManifestAad(h));
    final plain=decodeSyncCompression(packed,h['meta_codec'] as String,h['meta_size'] as int);
    if(lanSha256(plain)!=h['meta_hash']) { throw const FormatException('Manifest metadata mismatch'); }
    final meta=jsonDecode(utf8.decode(plain)) as Map;
    if(h['kind']=='checkpoint' && jsonEncode(h['proof'])!=jsonEncode((meta['details'] as Map)['proof'])) {
      throw const FormatException('Checkpoint public proof mismatch');
    }
    final chunks=(meta['chunks'] as List).map((v)=>SyncBlobChunk.fromJson(Map<String,Object?>.from(v as Map))).toList();
    if(chunks.any((c)=>c.owner!=h['writer'] || c.epoch!=h['epoch']) ||
      jsonEncode(chunks.map((c)=>c.hash).toList())!=jsonEncode(h['chunks'])) { throw const FormatException('Manifest chunk context mismatch'); }
    blobs.files.guard?.call();
    return SyncManifest(bytes:bytes,header:h,details:Map<String,Object?>.from(meta['details'] as Map),chunks:chunks);
  }
}
