import 'dart:convert';
import 'transport/lan_protocol.dart';
import '../util/result.dart';
import 'sync_blob_store.dart';
import 'sync_manifest.dart';
import 'transport/relay_transport.dart';
import 'transport/vault_transport.dart';
import 'transport/lan_transport.dart';

class SyncTransferBudget {
  SyncTransferBudget({this.remaining=8*1024*1024,this.bytesPerSecond=2*1024*1024});
  int remaining, transferred=0;
  final int bytesPerSecond;
  bool get exhausted => remaining < SyncBlobChunk.maxPlainSize+40;
  Future<void> consume(int bytes) async {
    remaining-=bytes; transferred+=bytes;
    if(bytesPerSecond>0) await Future<void>.delayed(Duration(microseconds:bytes*1000000~/bytesPerSecond));
  }
}

class SyncContentTransfer {
  SyncContentTransfer(this.codec,this.client,this.budget,{String? providerDeviceId})
      : providerDeviceId=providerDeviceId ?? (client is LanTransport ? client.peer.deviceId : null);
  final String? providerDeviceId;
  final SyncManifestCodec codec;
  final VaultTransport client;
  final SyncTransferBudget budget;
  T value<T>(Result<T> result) {
    if(result is Ok<T>) return result.value;
    final error=result as Err<T>; throw StateError('${error.code}: ${error.message}');
  }
  final _knownManifests=<String,String>{};
  Future<void> checkUploadedManifests(List<String> paths) async {
    for(var i=0;i<paths.length;i+=256) {
      codec.blobs.files.guard?.call();
      _knownManifests.addAll(value(await (client as RelayTransport).inventory(
        paths.sublist(i,(i+256).clamp(0,paths.length)))));
    }
  }
  Future<bool> upload(SyncManifest manifest) async {
    final audit=codec.blobs.files.file('cache/upload-audit-${manifest.hash}');
    // A remote manifest plus a recent full audit avoids re-hashing every blob each minute.
    if(manifest.kind=='media' && _knownManifests[manifest.path]==manifest.hash &&
        audit.existsSync() && DateTime.now().difference(audit.lastModifiedSync()).inMinutes<60) {
      return true;
    }
    final paths={...manifest.chunks.map((c)=>c.path),manifest.path}.toList();
    final found=<String,String>{};
    for(var i=0;i<paths.length;i+=256) {
      codec.blobs.files.guard?.call();
      found.addAll(value(await (client as RelayTransport).inventory(paths.sublist(i,(i+256).clamp(0,paths.length)))));
    }
    for(final chunk in manifest.chunks) {
      codec.blobs.files.guard?.call();
      if(found[chunk.path]==chunk.hash) continue;
      if(chunk.size>budget.remaining) return false;
      value(await client.put(chunk.path,await codec.blobs.frame(chunk)));
      found[chunk.path]=chunk.hash; await budget.consume(chunk.size);
    }
    if(found[manifest.path]!=manifest.hash) {
      if(manifest.bytes.length>budget.remaining) return false;
      value(await client.put(manifest.path,manifest.bytes)); await budget.consume(manifest.bytes.length);
    }
    codec.blobs.files.guard?.call();
    if(manifest.kind=='media') {
      await codec.blobs.files.write('cache/upload-audit-${manifest.hash}',[]);
    }
    return true;
  }

  Future<SyncManifest?> manifest(String owner,String hash) async {
    Future<SyncManifest?> openAvailable(List<int> bytes) async {
      if(lanSha256(bytes)!=hash) throw const FormatException('Manifest hash mismatch');
      final envelope=jsonDecode(utf8.decode(bytes)) as Map;
      final header=jsonDecode(utf8.decode(base64Url.decode(
        base64Url.normalize(envelope['payload'] as String)))) as Map;
      if(!codec.blobs.epochKeys.containsKey(header['epoch']) || !codec.signers.containsKey(header['writer'])) return null;
      return codec.open(bytes,expectedHash:hash);
    }
    final path='manifests/$owner/$hash.json';
    final files=codec.blobs.files;
    if(files.file(path).existsSync()) {
      try {
        return await openAvailable(await files.read(path,limit:SyncManifestCodec.maxBytes));
      } on FormatException {
        files.file(path).deleteSync();
      }
    }
    List<int> bytes;
    if(providerDeviceId != null) {
      final response=await client.get('content/$providerDeviceId/$hash.json');
      if(response is Err<List<int>>) return null;
      bytes=(response as Ok<List<int>>).value;
    } else {
      final present=value(await (client as RelayTransport).inventory([path]));
      if(present[path]!=hash) return null;
      bytes=value(await client.get(path));
    }
    await budget.consume(bytes.length);
    final result=await openAvailable(bytes);
    await files.write(path,bytes); return result;
  }

  Future<bool> download(SyncManifest manifest) async {
    final missing=<SyncBlobChunk>[];
    for(final chunk in manifest.chunks) {
      if(codec.blobs.files.file(chunk.path).existsSync()) {
        try { await codec.blobs.frame(chunk);continue; }
        on FormatException { codec.blobs.files.file(chunk.path).deleteSync(); }
      }
      missing.add(chunk);
    }
    for(final chunk in missing) {
      codec.blobs.files.guard?.call();
      if(chunk.size>budget.remaining) return false;
      List<int> frame;
      if(providerDeviceId != null) {
        final response=await client.get('content/$providerDeviceId/${chunk.hash}.bin');
        if(response is Err<List<int>>) return false;
        frame=(response as Ok<List<int>>).value;
      } else {
        final found=value(await (client as RelayTransport).inventory([chunk.path]));
        if(found[chunk.path]!=chunk.hash) return false;
        frame=value(await client.get(chunk.path));
      }
      await codec.blobs.saveFrame(chunk,frame); await budget.consume(frame.length);
    }
    codec.blobs.files.guard?.call(); return true;
  }
}
