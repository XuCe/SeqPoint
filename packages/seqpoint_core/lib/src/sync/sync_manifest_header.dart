import 'dart:convert';

void validateSyncManifestHeader(Map<String,Object?> h,String vault) {
  final id=RegExp(r'^[A-Za-z0-9_-]{43}$'),hash=RegExp(r'^[a-f0-9]{64}$');
  final sequence=h['sequence'],epoch=h['epoch'],size=h['meta_size'],chunks=h['chunks'];
  if(h['version']!=2 || h['vault']!=vault || !const {'media','checkpoint'}.contains(h['kind']) ||
    h['writer'] is! String || !id.hasMatch(h['writer'] as String) ||
    h['author'] is! String || !id.hasMatch(h['author'] as String) ||
    h['subject'] is! String || !RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(h['subject'] as String) ||
    epoch is! int || epoch<1 || sequence is! int || sequence<0 || sequence>9007199254740991 ||
    h['anchor'] is! String || !hash.hasMatch(h['anchor'] as String) ||
    h['membership'] is! String || !id.hasMatch(h['membership'] as String) ||
    h['meta_hash'] is! String || !hash.hasMatch(h['meta_hash'] as String) ||
    size is! int || size<1 || size>8*1024*1024 || !const {'raw','gzip'}.contains(h['meta_codec']) ||
    chunks is! List || chunks.length>16384 || chunks.any((v)=>v is! String || !hash.hasMatch(v))) {
    throw const FormatException('Invalid sync manifest header');
  }
  if(h['kind']=='media' && (h['author']!=h['writer'] || sequence!=0)) {
    throw const FormatException('Invalid media author');
  }
}

List<int> syncManifestAad(Map<String,Object?> h) => utf8.encode([
  'seqpoint-manifest-v2',h['vault'],h['writer'],h['author'],h['epoch'],h['kind'],h['subject'],
  h['sequence'],h['anchor'],h['membership'],h['meta_hash'],h['meta_codec'],h['meta_size'],
  jsonEncode(h['chunks'])].join('\n'));
