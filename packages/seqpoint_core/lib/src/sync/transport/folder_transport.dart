import 'dart:io';

import '../../util/result.dart';
import '../sync_files.dart';
import 'lan_protocol.dart';
import 'vault_transport.dart';

/// A separate encrypted publication directory; never the raw vault directory.
class FolderTransport implements VaultTransport {
  FolderTransport(this.root, {required this.writerDeviceId, LanLimits? limits})
    : limits = limits ?? LanLimits(),
      files = SyncFiles(root);

  final Directory root;
  final String writerDeviceId;
  final LanLimits limits;
  final SyncFiles files;

  Future<Result<void>> pruneOperations(
    int throughSequence, {
    void Function()? guard,
  }) async {
    try {
      if (throughSequence < 1) return const Ok(null);
      final guarded = SyncFiles(root, guard: guard);
      final directory = guarded.file('ops/$writerDeviceId/probe').parent;
      if (!await directory.exists()) return const Ok(null);
      var scanned = 0;
      await for (final entity in directory.list(followLinks: false)) {
        guard?.call();
        if (++scanned > 4096) throw StateError('Too many directory entries');
        final name = entity.uri.pathSegments.last;
        final path = 'ops/$writerDeviceId/$name';
        if (entity is! File || !lanOwnedPath(path, writerDeviceId)) continue;
        final sequence = int.parse(name.split('-').last.split('.').first);
        if (sequence <= throughSequence) guarded.file(path).deleteSync();
      }
      return const Ok(null);
    } catch (_) {
      return const Err(
        'folder_prune',
        message: 'Cannot reclaim covered publications',
      );
    }
  }

  bool _valid(String path) {
    final parts = path.split('/');
    if (parts.length < 2) return false;
    final owner = switch (parts.first) {
      'members' || 'acks' => parts.last.replaceFirst(RegExp(r'\.json$'), ''),
      'ops' || 'checkpoints' || 'content' => parts[1],
      _ => '',
    };
    return lanOwnedPath(path, owner);
  }

  @override
  String get id => 'folder';

  @override
  TransportStatus get status =>
      const TransportStatus(kind: TransportStatusKind.localOnly);

  @override
  Future<Result<List<RemoteFile>>> list(String dirPath) async {
    try {
      if (!{'members', 'acks'}.contains(dirPath) &&
          !RegExp(r'^(ops|checkpoints|content)/[A-Za-z0-9_-]{43}$')
              .hasMatch(dirPath)) {
        throw ArgumentError('Invalid publication directory');
      }
      final directory = files.file('$dirPath/probe').parent;
      if (!await directory.exists()) return const Ok([]);
      final result = <RemoteFile>[];
      var scanned = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (++scanned > 4096) throw StateError('Too many directory entries');
        final name = entity.uri.pathSegments.last;
        final path = '$dirPath/$name';
        if (entity is! File || !_valid(path)) continue;
        final stat = await files.file(path).stat();
        if (stat.size > limits.maxFileBytes ||
            result.length >= limits.maxFiles) {
          throw StateError('Publication exceeds limits');
        }
        result.add(
          RemoteFile(name: name, size: stat.size, modifiedAt: stat.modified),
        );
      }
      result.sort((a, b) => a.name.compareTo(b.name));
      return Ok(result);
    } catch (_) {
      return const Err(
        'folder_list',
        message: 'Cannot read publication directory',
      );
    }
  }

  @override
  Future<Result<List<int>>> get(String filePath) async {
    try {
      if (!_valid(filePath)) throw ArgumentError('Invalid publication path');
      return Ok(await files.read(filePath, limit: limits.maxFileBytes));
    } catch (_) {
      return const Err('folder_get', message: 'Publication is unavailable');
    }
  }

  @override
  Future<Result<void>> put(
    String filePath,
    List<int> bytes, {
    void Function()? guard,
  }) async {
    try {
      final guarded = SyncFiles(root, guard: guard);
      if (!_valid(filePath) ||
          !lanOwnedPath(filePath, writerDeviceId) ||
          bytes.length > limits.maxFileBytes ||
          bytes.any((b) => b < 0 || b > 255)) {
        throw ArgumentError('Invalid owned publication');
      }
      final file = guarded.file(filePath);
      if (await file.exists() && await file.length() == bytes.length) {
        final previous = await guarded.read(
          filePath,
          limit: limits.maxFileBytes,
        );
        var equal = previous.length == bytes.length;
        for (var i = 0; equal && i < previous.length; i++) {
          equal = previous[i] == bytes[i];
        }
        if (equal) return const Ok(null);
      }
      await guarded.write(filePath, bytes);
      return const Ok(null);
    } catch (_) {
      return const Err('folder_put', message: 'Cannot publish file');
    }
  }

  @override
  Future<Result<void>> delete(String filePath) async {
    try {
      if (!_valid(filePath) || !lanOwnedPath(filePath, writerDeviceId)) {
        throw ArgumentError('Invalid owned publication');
      }
      final file = files.file(filePath);
      if (await file.exists()) await files.file(filePath).delete();
      return const Ok(null);
    } catch (_) {
      return const Err('folder_delete', message: 'Cannot delete publication');
    }
  }
}
