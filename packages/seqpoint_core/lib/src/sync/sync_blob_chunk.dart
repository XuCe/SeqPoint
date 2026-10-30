/// Immutable encrypted content address and authenticated decoding limits.
class SyncBlobChunk {
  SyncBlobChunk({
    required this.owner,
    required this.epoch,
    required this.hash,
    required this.plainHash,
    required this.plainSize,
    required this.size,
    required this.codec,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(owner) ||
        epoch < 1 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(plainHash) ||
        plainSize < 1 ||
        plainSize > maxPlainSize ||
        size < 40 ||
        size > maxPlainSize + 40 ||
        !const {'raw', 'gzip'}.contains(codec)) {
      throw const FormatException('Invalid encrypted chunk');
    }
  }
  static const maxPlainSize = 1024 * 1024;
  final String owner, hash, plainHash, codec;
  final int epoch, plainSize, size;
  String get path => 'blobs/$owner/$hash.bin';
  Map<String, Object> toJson() => {
    'owner': owner,
    'epoch': epoch,
    'hash': hash,
    'plain_hash': plainHash,
    'plain_size': plainSize,
    'size': size,
    'codec': codec,
  };
  factory SyncBlobChunk.fromJson(Map<String, Object?> json) => SyncBlobChunk(
    owner: json['owner'] as String,
    epoch: json['epoch'] as int,
    hash: json['hash'] as String,
    plainHash: json['plain_hash'] as String,
    plainSize: json['plain_size'] as int,
    size: json['size'] as int,
    codec: json['codec'] as String,
  );
}
