import 'dart:convert';
import 'dart:io';

import '../crypto/xchacha20_aead.dart';

List<int> _aad(
  String vault,
  String owner,
  int epoch,
  String hash,
  int size,
  String codec,
) => utf8.encode(
  ['seqpoint-blob-v2', vault, owner, epoch, hash, size, codec].join('\n'),
);

Future<({String codec, List<int> frame})> encodeSyncBlob(
  List<int> plain,
  List<int> key,
  String vault,
  String owner,
  int epoch,
  String hash,
) async {
  final compressed = GZipCodec(level: 6).encode(plain);
  final useGzip = compressed.length * 100 <= plain.length * 95;
  final codec = useGzip ? 'gzip' : 'raw';
  final frame = await XChaCha20Aead().seal(
    useGzip ? compressed : plain,
    key,
    aad: _aad(vault, owner, epoch, hash, plain.length, codec),
  );
  return (codec: codec, frame: frame);
}

Future<List<int>> decodeSyncBlob(
  List<int> frame,
  List<int> key,
  String vault,
  String owner,
  int epoch,
  String hash,
  int size,
  String codec,
) async {
  final compressed = await XChaCha20Aead().open(
    frame,
    key,
    aad: _aad(vault, owner, epoch, hash, size, codec),
  );
  return decodeSyncCompression(compressed, codec, size);
}

List<int> decodeSyncCompression(List<int> compressed, String codec, int size) {
  if (size < 0 || size > 12 * 1024 * 1024 || !const {'gzip', 'raw'}.contains(codec)) {
    throw const FormatException('Invalid compression bounds');
  }
  final output = _LimitedBytes(size);
  if (codec == 'gzip') {
    final decoder = gzip.decoder.startChunkedConversion(output);
    decoder.add(compressed);
    decoder.close();
  } else {
    output.add(compressed);
  }
  if (output.bytes.length != size) {
    throw const FormatException('Decoded chunk length mismatch');
  }
  return output.bytes;
}

class _LimitedBytes implements Sink<List<int>> {
  _LimitedBytes(this.limit);
  final int limit;
  final bytes = <int>[];
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException('Decompression limit exceeded');
    }
    bytes.addAll(data);
  }

  @override
  void close() {}
}

/// Framed inside AEAD, so the compression flag and decoded length are authenticated.
List<int> compressSyncPayload(List<int> plain) {
  final compressed=GZipCodec(level:6).encode(plain),size=plain.length;
  if((compressed.length+8)*100>size*95) return plain;
  return [83,80,90,50,(size>>24)&255,(size>>16)&255,(size>>8)&255,size&255,...compressed];
}

List<int> expandSyncPayload(List<int> packed,int limit) {
  if(packed.length>=8 && packed[0]==83 && packed[1]==80 && packed[2]==90 && packed[3]==50) {
    final size=(packed[4]<<24)|(packed[5]<<16)|(packed[6]<<8)|packed[7];
    if(size>limit) throw const FormatException('Segment decompression limit exceeded');
    return decodeSyncCompression(packed.sublist(8),'gzip',size);
  }
  if(packed.length>limit) throw const FormatException('Segment length limit exceeded');
  return packed;
}
