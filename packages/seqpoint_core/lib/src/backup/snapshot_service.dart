import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/migrations.dart';
import '../util/clock.dart';
import '../util/ids.dart';

/// 一份本地快照。
class Snapshot {
  const Snapshot({required this.file, required this.createdAt, required this.bytes});

  final File file;
  final DateTime createdAt;
  final int bytes;
}

/// 本地快照。四层备份的第一层。
///
/// 用 SQLite 的 `VACUUM INTO` 生成一致性快照——它在事务中完成，
/// 不需要停写，也不会拷到写了一半的页。默认每日一份、保留 7 份。
///
/// 注意：快照是数据库的完整副本，加密与否取决于源库是否用 SQLCipher 打开。
/// 导出到设备之外的备份见 export/exporters.dart。
class SnapshotService {
  SnapshotService(this._db, {Clock clock = const SystemClock()})
      : _clock = clock;

  final SeqDatabase _db;
  final Clock _clock;

  static const filePrefix = 'seqpoint-';
  static const fileSuffix = '.snapshot.db';

  /// 只读校验快照，返回可支持的版本；不迁移或修改原文件。
  static int validate(File snapshot) {
    if (!snapshot.existsSync()) {
      throw FileSystemException('快照不存在', snapshot.path);
    }
    final probe = sqlite3.open(snapshot.path, mode: OpenMode.readOnly);
    final expected = SeqDatabase.inMemory();
    try {
      probe.execute('PRAGMA trusted_schema = OFF');
      final version = probe.select('PRAGMA user_version').single.columnAt(0) as int;
      if (version < 1 || version > latestSchemaVersion) {
        throw StateError('不支持的快照版本：$version');
      }
      if (probe.select('SELECT name FROM sqlite_master WHERE type IN (?, ?)',
          ['trigger', 'view']).isNotEmpty) {
        throw StateError('快照包含当前格式不支持的触发器或视图');
      }
      final integrity = probe.select('PRAGMA integrity_check');
      if (integrity.length != 1 || integrity.single.columnAt(0) != 'ok') {
        throw StateError('快照完整性校验失败');
      }
      if (probe.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw StateError('快照包含无效的数据关联');
      }
      for (var v = 1; v <= version; v++) {
        for (final sql in migrations[v]!) { expected.raw.execute(sql); }
      }
      for (final row in expected.raw.select('SELECT name FROM sqlite_master '
          "WHERE type='table' AND name NOT LIKE 'sqlite_%'")) {
        final name = row['name'] as String;
        final columns = probe.select('SELECT * FROM pragma_table_info(?)', [name]);
        if (columns.isEmpty) throw StateError('快照缺少必要数据表：$name');
        final actual = {for (final column in columns) column['name']: column};
        final reference = expected.raw.select('SELECT * FROM pragma_table_info(?)', [name]);
        for (final column in reference) {
          final found = actual[column['name']];
          if (found == null || const ['type', 'notnull', 'pk']
              .any((key) => found[key] != column[key])) {
            throw StateError('快照数据列不兼容：$name.${column['name']}');
          }
        }
        final known = reference.map((column) => column['name']).toSet();
        if (columns.any((column) {
          final value = column['dflt_value']?.toString()
              .replaceAll(RegExp(r'[\s()]'), '').toUpperCase();
          return !known.contains(column['name']) && column['notnull'] == 1 &&
              (value == null || value == 'NULL');
        })) {
          throw StateError('快照包含无有效默认值的额外必填列：$name');
        }
        final required = _constraints(expected.raw, name);
        final found = _constraints(probe, name);
        if (found.length != required.length || !found.containsAll(required)) {
          throw StateError('快照数据约束不兼容：$name');
        }
      }
      return version;
    } finally {
      expected.close();
      probe.dispose();
    }
  }

  static Set<String> _constraints(Database database, String table) => {
    for (final row in database.select('SELECT * FROM pragma_foreign_key_list(?)', [table]))
      jsonEncode(['fk', for (final key in ['seq', 'table', 'from', 'to',
        'on_update', 'on_delete', 'match']) row[key]]),
    for (final index in database.select(
        'SELECT name, partial FROM pragma_index_list(?) WHERE "unique"=1', [table]))
      jsonEncode(['unique', index['partial'],
        for (final column in database.select('SELECT name, coll, "desc" '
            'FROM pragma_index_xinfo(?) WHERE "key"=1 ORDER BY seqno', [index['name']]))
          [column['name'], column['coll'], column['desc']],
      ]),
  };

  /// 在 [dir] 生成今日快照并轮转旧文件。
  ///
  /// 同一天重复调用会覆盖当天的快照，不会占用多个名额。
  Future<Snapshot> createDaily(Directory dir, {int keep = 7}) async {
    if (keep < 1) throw ArgumentError.value(keep, 'keep', '至少保留 1 份');
    final now = _clock.now();
    final snapshot = await _create(dir, now, _nameFor(now));
    await _rotate(dir, keep: keep);
    return snapshot;
  }

  /// 手动快照独立命名，不覆盖或自动清理历史手动备份。
  Future<Snapshot> createManual(Directory dir) {
    final now = _clock.now();
    final stamp = now.toUtc().toIso8601String().replaceAll(':', '');
    return _create(dir, now, '$filePrefix$stamp--${newId()}$fileSuffix');
  }

  Future<Snapshot> _create(Directory dir, DateTime now, String name) async {
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, name));
    // 新快照生成成功后再替换，失败时保留旧文件。
    final staging = await dir.createTemp('.snapshot-');
    final pending = File(p.join(staging.path, 'snapshot.db'));
    try {
      _db.raw.execute('VACUUM INTO ?', [pending.path]);
      await pending.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }

    return Snapshot(
      file: file,
      createdAt: now,
      bytes: file.lengthSync(),
    );
  }

  /// 列出目录中的快照，最新的在前。
  Future<List<Snapshot>> list(Directory dir) async {
    if (!dir.existsSync()) return const [];
    final snapshots = <Snapshot>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final date = _dateFrom(name);
      if (date == null) continue;
      snapshots.add(Snapshot(
        file: entity,
        createdAt: date,
        bytes: entity.lengthSync(),
      ));
    }
    snapshots.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return snapshots;
  }

  /// 离线恢复：候选迁移/断开同步/校验后，同盘替换 [targetPath]。
  ///
  /// 调用方必须先关闭数据库连接，恢复后重新打开——本方法不碰活动连接。
  Future<void> restore(File snapshot, {required String targetPath}) async {
    final target = File(targetPath).absolute;
    if (target.existsSync() && FileSystemEntity.identicalSync(snapshot.path, target.path)) {
      throw ArgumentError('源快照不能是目标数据库');
    }
    for (final path in [snapshot.absolute.path, target.path]) {
      for (final suffix in ['-wal', '-shm', '-journal']) {
        if (FileSystemEntity.typeSync('$path$suffix', followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('数据库仍有事务辅助文件，请先关闭相关窗口');
        }
      }
    }
    validate(snapshot);
    final staging = await target.parent.createTemp('.seqpoint-restore-');
    final pending = File(p.join(staging.path, 'restore.db'));
    try {
      await snapshot.copy(pending.path);
      final candidate = SeqDatabase.open(pending.path);
      try {
        candidate.migrate();
        candidate.disconnectSyncForRestore();
      } finally { candidate.close(); }
      validate(pending);
      await pending.rename(target.path);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<void> _rotate(Directory dir, {required int keep}) async {
    final all = await list(dir);
    final daily = all.where((s) => p.basename(s.file.path) == _nameFor(s.createdAt));
    for (final old in daily.skip(keep)) {
      if (old.file.existsSync()) old.file.deleteSync();
    }
  }

  String _nameFor(DateTime t) {
    final y = t.year.toString().padLeft(4, '0');
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '$filePrefix$y-$m-$d$fileSuffix';
  }

  DateTime? _dateFrom(String fileName) {
    if (!fileName.startsWith(filePrefix) || !fileName.endsWith(fileSuffix)) {
      return null;
    }
    final stamp = fileName.substring(
        filePrefix.length, fileName.length - fileSuffix.length);
    return DateTime.tryParse(stamp.split('--').first);
  }
}
