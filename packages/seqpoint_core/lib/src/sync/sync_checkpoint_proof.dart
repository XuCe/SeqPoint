import 'dart:convert';
import '../crypto/ed25519_signer.dart';
import '../identity/device_keys.dart';
import 'sync_blob_chunk.dart';

List<Object> _facts(List<SyncBlobChunk> chunks) =>
    chunks.map((c) => [c.plainHash, c.plainSize]).toList();

Future<Map<String, Object?>> signCheckpointProof({required DeviceKeys keys,
  required String vault, required int sequence, required String anchor,
  required String membership, required List<SyncBlobChunk> chunks}) async {
  final payload = utf8.encode(jsonEncode({'domain':'seqpoint-checkpoint-v2',
    'vault':vault,'author':keys.deviceId,'sequence':sequence,'anchor':anchor,
    'membership':membership,'facts':_facts(chunks)}));
  return {'payload':base64UrlEncode(payload),
    'signature':base64UrlEncode(await keys.signer.sign(payload))};
}

Future<void> verifyCheckpointProof(Map<String,Object?> proof, {
  required String author, required List<int> publicKey, required String vault,
  required int sequence, required String anchor,
  required List<SyncBlobChunk> chunks}) async {
  final payload = base64Url.decode(proof['payload'] as String);
  if (payload.length > 2*1024*1024) {
    throw const FormatException('Checkpoint proof too large');
  }
  final h = jsonDecode(utf8.decode(payload)) as Map;
  if (h['domain'] != 'seqpoint-checkpoint-v2' || h['vault'] != vault ||
      h['author'] != author || h['sequence'] != sequence || sequence < 1 ||
      h['anchor'] != anchor || !RegExp(r'^[a-f0-9]{64}$').hasMatch(anchor) ||
      h['membership'] is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(h['membership'] as String) ||
      jsonEncode(h['facts']) != jsonEncode(_facts(chunks)) ||
      !await Ed25519Signer.verifyPublic(payload,
        base64Url.decode(proof['signature'] as String), publicKey)) {
    throw const FormatException('Invalid original checkpoint proof');
  }
}
