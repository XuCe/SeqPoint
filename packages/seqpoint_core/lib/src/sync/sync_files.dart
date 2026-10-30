import 'dart:io';

import '../util/ids.dart';

/// Bounded cache IO shared by media and checkpoint transfers.
class SyncFiles {
  SyncFiles(this.root, {this.guard});
  final Directory root;
  final void Function()? guard;
  File file(String relative) {
    guard?.call();
    if (!RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(relative) ||
        relative
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError('Invalid sync path');
    }
    var path = root.path;
    for (final part in ['', ...relative.split('/')]) {
      if (part.isNotEmpty) path = '$path/$part';
      if (FileSystemEntity.isLinkSync(path)) {
        throw StateError('Sync cannot follow symbolic links');
      }
    }
    return File(path);
  }

  Future<List<int>> read(String relative, {required int limit}) async {
    final result = <int>[];
    await for (final chunk in file(relative).openRead()) {
      guard?.call();
      if (result.length + chunk.length > limit) {
        throw StateError('Sync file exceeds limit');
      }
      result.addAll(chunk);
    }
    file(relative);
    return result;
  }

  Future<void> write(String relative, List<int> bytes) async {
    final target = file(relative);
    await target.parent.create(recursive: true);
    file(relative);
    final temporary = File('${target.path}.tmp.${newId()}');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      file(relative);
      temporary.renameSync(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
