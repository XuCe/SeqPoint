import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../model/enums.dart';
import '../model/item.dart';
import '../repo/item_repository.dart';
import '../repo/mappers.dart';
import '../repo/note_repository.dart';
import '../repo/tag_repository.dart';
import '../util/clock.dart';
import '../util/ids.dart';

/// 数据可带走：随时导出为 JSON 或 Markdown。
///
/// 导出文件中不含任何密钥——secrets 表整体跳过。用户的 AI 密钥留在
/// 各设备的系统安全存储里，导出件即使泄露也拿不到它。
abstract interface class Exporter {
  /// 导出到 [target] 目录，返回生成的文件。
  Future<File> export(Directory target);
}

/// 可读 JSON 导出：便签、事项及其关联记录，不作为快照恢复输入。
class JsonExporter implements Exporter {
  JsonExporter(
    this._db, {
    this.includeArchived = true,
    this.includeTrashed = false,
    Clock clock = const SystemClock(),
  }) : _clock = clock;

  final SeqDatabase _db;
  final bool includeArchived;
  final bool includeTrashed;
  final Clock _clock;

  /// 导出格式版本。将来结构变化时用它做兼容判断。
  static const formatVersion = 1;

  @override
  Future<File> export(Directory target) async {
    final content = const JsonEncoder.withIndent('  ').convert(build());
    await target.create(recursive: true);
    final staging = await target.createTemp('.seqpoint-export-');
    try {
      final file = File(p.join(staging.path, 'export.json'));
      await file.writeAsString(content, flush: true);
      return await file.rename(p.join(target.path, _fileName()));
    } finally {
      await staging.delete(recursive: true);
    }
  }

  /// 构造导出内容。抽出来便于测试与复用。
  Map<String, Object?> build() => _db.transaction(() {
    final notes = _db.raw.select('SELECT * FROM notes').where((r) =>
        (includeTrashed || r['deleted_at'] == null) &&
        (includeArchived || r['status'] != 'closed')).toList();
    final noteIds = notes.map((r) => r['id']).toSet();
    final items = _db.raw.select('SELECT * FROM items').where((r) =>
        (includeTrashed || r['deleted_at'] == null) &&
        (r['note_id'] == null || noteIds.contains(r['note_id']))).toList();
    final itemIds = items.map((r) => r['id']).toSet();
    final itemTags = _db.raw.select('SELECT * FROM item_tags')
        .where((r) => itemIds.contains(r['item_id'])).toList();
    final tagIds = itemTags.map((r) => r['tag_id']).toSet();
    final tags = _db.raw.select('SELECT * FROM tags')
        .where((r) => tagIds.contains(r['id'])).toList();
    final reminders = _db.raw.select('SELECT * FROM reminders')
        .where((r) => itemIds.contains(r['item_id'])).toList();
    final objectIds = {
      'note': noteIds, 'item': itemIds, 'tag': tagIds,
      'reminder': reminders.map((r) => r['id']).toSet(),
    };
    final activities = _db.raw.select('SELECT * FROM activities').where((r) =>
        objectIds[r['object_type']]?.contains(r['object_id']) ?? false).toList();

    return {
      'format': 'seqpoint-export',
      'format_version': formatVersion,
      'exported_at': encodeTime(_clock.now()),
      'schema_version': _db.schemaVersion,
      // secrets 表刻意不导出：密钥只属于系统安全存储。
      'notes': notes.map(_rowToMap).toList(),
      'items': items.map(_rowToMap).toList(),
      'tags': tags.map(_rowToMap).toList(),
      'item_tags': itemTags.map(_rowToMap).toList(),
      'reminders': reminders.map(_rowToMap).toList(),
      'activities': activities.map(_rowToMap).toList(),
    };
  });

  Map<String, Object?> _rowToMap(dynamic row) => {
        for (final key in row.keys as List) key as String: row[key],
      };

  String _fileName() {
    final t = _clock.now();
    final stamp = '${t.year.toString().padLeft(4, '0')}'
        '${t.month.toString().padLeft(2, '0')}'
        '${t.day.toString().padLeft(2, '0')}';
    return 'seqpoint-export-$stamp-${newId()}.json';
  }
}

/// Markdown 导出：一张便签一个文件，事项渲染为 checkbox 列表。
///
/// 目标是"人能读、别的笔记软件能吃"，不追求可再导入。
class MarkdownExporter implements Exporter {
  MarkdownExporter(
    this._db, {
    this.includeArchived = true,
    Clock clock = const SystemClock(),
  }) : _clock = clock;

  final SeqDatabase _db;
  final bool includeArchived;
  final Clock _clock;

  @override
  Future<File> export(Directory target) async {
    final files = build();
    await target.create(recursive: true);
    final staging = await target.createTemp('.seqpoint-markdown-');
    try {
      for (final entry in files.entries) {
        await File(p.join(staging.path, entry.key))
            .writeAsString(entry.value, flush: true);
      }
      final destination = p.join(target.path, 'seqpoint-markdown-${newId()}');
      await staging.rename(destination);
      return File(p.join(destination, 'README.md'));
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// 同步收集可读文件内容；调用者可直接打包，不写磁盘。
  Map<String, String> build() => _db.transaction(() {
    final files = <String, String>{};
    final notes = NoteRepository(_db, clock: _clock);
    final items = ItemRepository(_db, clock: _clock);
    final tags = TagRepository(_db);

    final all = [
      ...notes.active(),
      if (includeArchived) ...notes.closed(limit: -1),
    ];

    final indexLines = <String>['# 序点导出', ''];
    for (final note in all) {
      final noteItems = items.byNote(note.id);
      final buffer = StringBuffer();
      final title = _titleOf(note.title, note.rawContent);
      buffer.writeln('# $title');
      buffer.writeln();
      buffer.writeln('> 创建于 ${_formatDate(note.createdAt)}'
          '${note.isClosed ? ' · 已关闭于 ${_formatDate(note.closedAt!)}' : ''}');
      buffer.writeln();

      // 事项按行号回填到原文对应位置，其余行原样保留。
      final lines = note.lines;
      final byLine = {
        for (final i in noteItems)
          if (i.lineIndex != null && i.lineIndex! >= 0 &&
              i.lineIndex! < lines.length &&
              lines[i.lineIndex!].trim() == i.title) i.lineIndex!: i,
      };
      final rendered = <String>{};
      for (var i = 0; i < lines.length; i++) {
        final item = byLine[i];
        if (item == null) {
          buffer.writeln(lines[i]);
          continue;
        }
        rendered.add(item.id);
        buffer.writeln(_itemLine(item, items, tags));
      }

      // 重复、越界或没有行号的事项也必须保留。
      final orphans = noteItems.where((i) => !rendered.contains(i.id));
      for (final item in orphans) {
        buffer.writeln(_itemLine(item, items, tags));
      }

      final fileName = _safeFileName(title);
      files[fileName] = buffer.toString();
      indexLines.add(_indexLink(title, fileName));
    }

    final standalone = _db.raw.select('SELECT * FROM items '
        'WHERE note_id IS NULL AND deleted_at IS NULL ORDER BY created_at, id')
        .map(RowMappers.item).toList();
    if (standalone.isNotEmpty) {
      final content = ['# 独立事项', '',
        ...standalone.map((item) => _itemLine(item, items, tags)), ''].join('\n');
      files['standalone-items.md'] = content;
      indexLines.add('- [独立事项](standalone-items.md)');
    }
    files['README.md'] = '${indexLines.join('\n')}\n';
    return files;
  });

  String _indexLink(String title, String fileName) {
    final label = title.replaceAll(r'\', r'\\').replaceAll('[', r'\[')
        .replaceAll(']', r'\]').replaceAll(RegExp(r'[\r\n]'), ' ');
    final destination = Uri.encodeComponent(fileName)
        .replaceAll('(', '%28').replaceAll(')', '%29');
    return '- [$label]($destination)';
  }

  String _itemLine(Item item, ItemRepository items, TagRepository tags) {
    final box = item.status == ItemStatus.done ? '[x]' : '[ ]';
    final tagNames = items.tagIdsOf(item.id).map((id) => tags.byId(id)?.name)
        .whereType<String>().map((name) => '#$name').join(' ');
    final due = item.dueAt == null ? '' : ' (${_formatDate(item.dueAt!)})';
    final title = item.status == ItemStatus.canceled ? '~~${item.title}~~ · 已取消' : item.title;
    return '- $box $title$due${tagNames.isEmpty ? '' : ' $tagNames'}';
  }

  String _titleOf(String? title, String rawContent) {
    if (title != null && title.trim().isNotEmpty) return title.trim();
    final firstLine = rawContent.split('\n').firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '无标题便签',
        );
    return firstLine.trim();
  }

  /// 标题清理路径字符；随机后缀避免同名碰撞和数据库ID进入文件路径。
  String _safeFileName(String title) {
    final cleaned = title
        .replaceAll(RegExp(r'[/\\:*?"<>|\n\r\t]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final short = cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
    return '${short.isEmpty ? '便签' : short}-${newId()}.md';
  }

  String _formatDate(DateTime t) {
    t = t.toLocal();
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
  }
}
