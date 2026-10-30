import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../model/attachment.dart';
import '../sync/attachment_sync_policy.dart';
import '../util/clock.dart';
import '../util/ids.dart';

class AttachmentService {
  AttachmentService({required this.db, required this.directory});
  final SeqDatabase db;
  final Directory directory;
  static const maxImageBytes = 20 * 1024 * 1024;
  static const maxAudioBytes = 50 * 1024 * 1024;

  Future<Attachment> addImage(
    Uint8List bytes, {
    String? noteId,
    String? itemId,
    String? name,
  }) async => _add(
    bytes,
    mime: _imageMime(bytes),
    noteId: noteId,
    itemId: itemId,
    name: name,
  );

  Future<Attachment> addAudio(
    Uint8List bytes, {
    required String noteId,
    String? name,
    bool Function()? canCommit,
  }) {
    if (bytes.length < 12 ||
        String.fromCharCodes(bytes.sublist(4, 8)) != 'ftyp' ||
        ![
          'M4A ',
          'isom',
          'mp42',
          'mp41',
        ].contains(String.fromCharCodes(bytes.sublist(8, 12)))) {
      return Future.error(ArgumentError('录音必须是 M4A 音频'));
    }
    return _add(
      bytes,
      mime: 'audio/mp4',
      media: 'audio',
      maxBytes: maxAudioBytes,
      noteId: noteId,
      name: name,
      canCommit: canCommit,
    );
  }

  Future<Attachment> _add(
    Uint8List bytes, {
    required String mime,
    String media = 'image',
    int maxBytes = maxImageBytes,
    String? noteId,
    String? itemId,
    String? name,
    bool Function()? canCommit,
  }) async {
    _owner(noteId, itemId);
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw ArgumentError('附件为空或超过大小限制');
    }
    final contents = Uint8List.fromList(bytes);
    final digest = await Sha256().hash(contents);
    final id = newId();
    final target = await file(id);
    final createdAt = DateTime.now().toUtc();
    final safeName = name == null
        ? null
        : p.basename(name.replaceAll('\\', '/'));
    _pending.add(id);
    try {
      await target.writeAsBytes(contents, flush: true);
      AttachmentSyncPolicy(db).capture(id, () {
        if (canCommit?.call() == false) throw StateError('录音保存已取消');
        _owner(noteId, itemId);
        final local = db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
        final shared = local['media_enabled'] == 1 && local['enabled'] == 1 &&
            local['requires_new_identity'] == 0;
        db.raw.execute(
          'INSERT INTO attachments '
          '(id,note_id,item_id,media,file_name,mime,byte_size,sha256,created_at,sync,content_owner) '
          'VALUES (?,?,?,?,?,?,?,?,?,?,?)',
          [
            id,
            noteId,
            itemId,
            media,
            safeName,
            mime,
            contents.length,
            digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
            encodeTime(createdAt),
            shared ? 'trusted_devices' : 'local_only',
            shared ? local['device_id'] : null,
          ],
        );
      });
    } catch (_) {
      if (await target.exists()) await target.delete();
      rethrow;
    } finally {
      _pending.remove(id);
    }
    return list(
      noteId: noteId,
      itemId: itemId,
      media: media,
    ).singleWhere((a) => a.id == id);
  }

  String _imageMime(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes.take(8).join(',') == '137,80,78,71,13,10,26,10') {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6 &&
        ['GIF87a', 'GIF89a'].contains(String.fromCharCodes(bytes.take(6)))) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      return 'image/webp';
    }
    throw ArgumentError('请选择 PNG、JPEG、GIF 或 WebP 图片');
  }

  List<Attachment> list({
    String? noteId,
    String? itemId,
    String media = 'image',
  }) {
    _owner(noteId, itemId);
    return db.raw
        .select(
          'SELECT * FROM attachments WHERE deleted_at IS NULL '
          'AND ${itemId == null ? 'note_id' : 'item_id'} = ? AND media = ? '
          'ORDER BY created_at,id',
          [itemId ?? noteId, media],
        )
        .map(Attachment.fromRow)
        .toList();
  }

  Future<void> remove(String id) async {
    if (!_safeId.hasMatch(id)) throw ArgumentError('无效的附件标识');
    AttachmentSyncPolicy(db).capture(id, () => db.raw.execute('UPDATE attachments SET deleted_at = ? WHERE id = ?', [
      encodeTime(DateTime.now().toUtc()),
      id,
    ]));
  }

  /// 未核实所有可恢复快照的引用时不删文件；墓碑行同样保留原文件。
  Future<int> cleanupOrphans({Set<String>? recoverableIds}) async {
    if (recoverableIds == null) return 0;
    await _ensureDirectory();
    var removed = 0;
    await for (final entry in directory.list(followLinks: false)) {
      final id = p.basename(entry.path);
      if (!_safeId.hasMatch(id) ||
          _pending.contains(id) ||
          recoverableIds.contains(id)) {
        continue;
      }
      if (db.raw.select('SELECT id FROM attachments WHERE id = ?', [
        id,
      ]).isNotEmpty) {
        continue;
      }
      if (entry is File || entry is Link) {
        await entry.delete();
        removed++;
      }
    }
    return removed;
  }

  static final _safeId = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  );
  static final _pending = <String>{};

  Future<File> file(String id) async {
    if (!_safeId.hasMatch(id)) {
      throw ArgumentError('无效的附件标识');
    }
    await _ensureDirectory();
    final file = File(p.join(directory.path, id));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw StateError('附件路径不可用');
    }
    return file;
  }

  Future<void> _ensureDirectory() async {
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('附件目录不可用');
    }
  }

  void _owner(String? noteId, String? itemId) {
    if ((noteId == null) == (itemId == null)) {
      throw ArgumentError('附件必须关联一个便签或事项');
    }
    final rows = db.raw.select(
      'SELECT id FROM ${itemId == null ? 'notes' : 'items'} '
      'WHERE id = ? AND deleted_at IS NULL',
      [itemId ?? noteId],
    );
    if (rows.isEmpty) throw StateError('关联的便签或事项已不存在');
  }
}
