import 'dart:convert';
import 'sync_blob_chunk.dart';
import 'transport/lan_protocol.dart';

/// Verified manifest data returned by SyncManifestCodec.
class SyncManifest {
  SyncManifest({required List<int> bytes,required Map<String,Object?> header,
    required Map<String,Object?> details,required List<SyncBlobChunk> chunks})
    : bytes=List.unmodifiable(bytes),_header=Map.unmodifiable(header),
      details=Map.unmodifiable(details),chunks=List.unmodifiable(chunks),hash=lanSha256(bytes);
  final List<int> bytes;
  final String hash;
  final Map<String,Object?> _header,details;
  final List<SyncBlobChunk> chunks;
  String get writer=>_header['writer'] as String;
  String get author=>_header['author'] as String;
  String get kind=>_header['kind'] as String;
  String get subject=>_header['subject'] as String;
  String get membershipHash=>_header['membership'] as String;
  int get epoch=>_header['epoch'] as int;
  int get sequence=>_header['sequence'] as int;
  String get anchor=>_header['anchor'] as String;
  String get path=>'manifests/$writer/$hash.json';
  String get contextHash=>lanSha256(utf8.encode(jsonEncode(
    Map<String,Object?>.of(_header)..remove('data'))));
}
