import 'package:seqpoint_core/seqpoint_core.dart';

/// 启动装配：打开数据库、迁移、写入内置标签、组装服务。
///
/// 顺序固定：数据库 → 迁移 → 内置数据 → 仓储 → 服务。
class Bootstrap {
  Bootstrap._(this.db, this.noteService, this.notes, this.items, this.tags,
      this.search);

  final SeqDatabase db;
  final NoteService noteService;
  final NoteRepository notes;
  final ItemRepository items;
  final TagRepository tags;
  final SearchService search;

  /// [dbPath] 为空时用内存库，便于测试与首次演示。
  static Future<Bootstrap> run({String? dbPath,
      bool recoverPendingRestore = true}) async {
    if (recoverPendingRestore && dbPath != null && dbPath != ':memory:') {
      await RestoreSession.recover(dbPath);
    }
    final db = dbPath == null ? SeqDatabase.inMemory() : SeqDatabase.open(dbPath);
    try {
      db.migrate();

      final notes = NoteRepository(db);
      final items = ItemRepository(db);
      final tags = TagRepository(db)..ensureBuiltins();
      final activities = ActivityRepository(db);
      final search = SearchService(db);

      final noteService = NoteService(
        db: db,
        notes: notes,
        items: items,
        activities: activities,
      );

      final boot =
          Bootstrap._(db, noteService, notes, items, tags, search);

      // 内存库意味着这是首次运行或演示环境，塞一条样例便签便于直观查看。
      // 接入真实数据目录后（M1 T1.4）此分支自然失效。
      if (dbPath == null) boot._seedDemo();

      return boot;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  /// 演示数据：一条会后待办便签，两件未完成、一件已完成。
  void _seedDemo() {
    final note = noteService.capture(
      '回复张三报价\n检查生产 nginx 证书\n周五前发周报',
      title: '会后待办',
    );
    final now = DateTime.now();
    final first = noteService.lineToItem(note.id, 0);
    items.update(first.copyWith(
      dueAt: DateTime(now.year, now.month, now.day, 18),
    ));
    noteService.lineToItem(note.id, 1);
    final third = noteService.lineToItem(note.id, 2);
    noteService.toggleItem(third.id);
  }

  void dispose() => db.close();
}
