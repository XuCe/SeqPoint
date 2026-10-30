import 'dart:io';
import 'dart:convert';
import 'dart:isolate';

import 'sync_blob_chunk.dart';
import 'sync_blob_codec.dart';
import 'sync_files.dart';
import 'transport/lan_protocol.dart';
export 'sync_blob_chunk.dart';

class SyncBlobStore {
  SyncBlobStore({
    required Directory root,
    required this.vaultId,
    required this.deviceId,
    required Map<int, List<int>> epochKeys,
    void Function()? guard,
  }) : files = SyncFiles(root, guard: guard),
       epochKeys = Map.unmodifiable(
         epochKeys.map(
           (epoch, key) => MapEntry(epoch, List<int>.unmodifiable(key)),
         ),
       );
  final String vaultId, deviceId;
  final Map<int, List<int>> epochKeys;
  final SyncFiles files;
  Future<SyncBlobChunk> encode(List<int> plain, {required int epoch}) async {
    if (plain.isEmpty || plain.length > SyncBlobChunk.maxPlainSize) {
      throw ArgumentError('Chunk plaintext exceeds limit');
    }
    final bytes = List<int>.unmodifiable(plain), key = epochKeys[epoch];
    if (key == null) {
      throw StateError('Chunk epoch key unavailable');
    }
    final hash = lanSha256(bytes), vault = vaultId, owner = deviceId;
    final cacheHash = lanSha256(
      utf8.encode(
        [
          'blob-cache-v2-gzip6-95',
          vault,
          owner,
          epoch,
          hash,
          bytes.length,
        ].join('\n'),
      ),
    );
    final cache = 'cache/$cacheHash.json';
    if (files.file(cache).existsSync()) {
      final chunk = SyncBlobChunk.fromJson(
        Map<String, Object?>.from(
          jsonDecode(utf8.decode(await files.read(cache, limit: 4096))) as Map,
        ),
      );
      if (chunk.plainHash != hash ||
          chunk.plainSize != bytes.length ||
          chunk.owner != owner ||
          chunk.epoch != epoch) {
        throw const FormatException('Chunk cache context mismatch');
      }
      if (files.file(chunk.path).existsSync()) {
        try {
          await decode(chunk);
          return chunk;
        } on FormatException {
          files.file(chunk.path).deleteSync();
        }
      }
    }
    final encoded = await Isolate.run(
      () => encodeSyncBlob(bytes, key, vault, owner, epoch, hash),
    );
    files.guard?.call();
    final chunk = SyncBlobChunk(
      owner: owner,
      epoch: epoch,
      hash: lanSha256(encoded.frame),
      plainHash: hash,
      plainSize: bytes.length,
      size: encoded.frame.length,
      codec: encoded.codec,
    );
    await saveFrame(chunk, encoded.frame);
    await files.write(cache, utf8.encode(jsonEncode(chunk.toJson())));
    return chunk;
  }

  Future<List<int>> frame(SyncBlobChunk chunk) async {
    if(files.file(chunk.path).lengthSync()!=chunk.size) {
      throw const FormatException('Encrypted chunk size mismatch');
    }
    final bytes = await files.read(chunk.path, limit: chunk.size);
    if (bytes.length != chunk.size || lanSha256(bytes) != chunk.hash) {
      throw const FormatException('Encrypted chunk hash mismatch');
    }
    return bytes;
  }

  Future<void> saveFrame(SyncBlobChunk chunk, List<int> bytes) async {
    if (bytes.length != chunk.size || lanSha256(bytes) != chunk.hash) {
      throw const FormatException('Encrypted chunk hash mismatch');
    }
    await files.write(chunk.path, bytes);
  }

  Future<List<int>> decode(SyncBlobChunk chunk) async {
    final bytes = await frame(chunk), key = epochKeys[chunk.epoch];
    if (key == null) {
      throw StateError('Chunk epoch key unavailable');
    }
    final vault = vaultId;
    final plain = await Isolate.run(
      () => decodeSyncBlob(
        bytes,
        key,
        vault,
        chunk.owner,
        chunk.epoch,
        chunk.plainHash,
        chunk.plainSize,
        chunk.codec,
      ),
    );
    files.guard?.call();
    if (lanSha256(plain) != chunk.plainHash) {
      throw const FormatException('Plain chunk hash mismatch');
    }
    return plain;
  }
}
