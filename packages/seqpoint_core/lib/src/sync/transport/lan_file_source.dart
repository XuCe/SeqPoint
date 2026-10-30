import 'dart:convert';

import 'lan_protocol.dart';
import 'published_file_view.dart';

/// Pure memory snapshot from persisted publications or signed control facts.
/// Never populate this by scanning or reading the transport's vault directory.
typedef LanPublishedFiles = Map<String, List<int>> Function();

/// Exposes only this device's published files; never exposes shared blobs.
class LanFileSource {
  LanFileSource(this.owner, this.publishedFiles, this.limits);
  final LanPublishedFiles publishedFiles;
  final String owner;
  final LanLimits limits;

  Future<List<int>> read(String path) async {
    if (!lanOwnedPath(path, owner)) throw ArgumentError('Unowned LAN file');
    final inventory = publishedFiles();
    final published = inventory[path];
    if (published == null || published.length > limits.maxFileBytes) {
      throw StateError('LAN file is not a bounded trusted publication');
    }
    final bytes = List<int>.unmodifiable(published);
    if (bytes.any((byte) => byte < 0 || byte > 255)) {
      throw StateError('Invalid published bytes');
    }
    return bytes;
  }

  Future<List<int>> list(String path) async {
    if (!lanOwnedPath(path, owner, directory: true)) {
      throw ArgumentError('Unowned LAN directory');
    }
    final published = publishedFiles();
    final inventory = published;
    final result = <Map<String, Object>>[];
    for (final key in inventory.keys) {
      if (!key.startsWith('$path/') || !lanOwnedPath(key, owner)) {
        continue;
      }
      final size = inventory is PublishedFileView ? inventory.size(key)! : inventory[key]!.length;
      if (size > limits.maxFileBytes) {
        throw StateError('LAN file too large');
      }
      result.add({'name': key.substring(path.length + 1), 'size': size});
    }
    if(result.length>limits.maxFiles) throw StateError('LAN listing too large');
    result.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    final bytes = utf8.encode(jsonEncode(result));
    if (bytes.length > limits.maxListBytes) {
      throw StateError('LAN listing too large');
    }
    return bytes;
  }
}
