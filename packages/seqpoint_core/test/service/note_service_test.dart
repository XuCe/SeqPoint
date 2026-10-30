import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late NoteService service;
  late FakeClock clock;

  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    clock = FakeClock(DateTime.parse('2026-09-03T09:00:00+08:00'));
    service = NoteService(
      db: db,
      notes: NoteRepository(db, clock: clock),
      items: ItemRepository(db, clock: clock),
      activities: ActivityRepository(db, clock: clock),
      clock: clock,
    );
  });

  tearDown(() => db.close());

  for (final (title, due) in [
    ('下周一提交报告', DateTime(2026, 9, 7, 9)),
    ('今晚八点开会', DateTime(2026, 9, 5, 20)),
    ('今晚零点提交', DateTime(2026, 9, 6)),
    ('下周提交报告', null),
    ('今晚123点提交', null),
  ]) {
    test('行转事项自动保存中文期限：$title', () {
      clock.set(DateTime(2026, 9, 5, 10));
      final note = service.capture(title);
      final item = service.lineToItem(note.id, 0);
      expect(item.dueAt?.toLocal(), due);
      final stored = ItemRepository(db).byId(item.id)!;
      expect(stored.dueAt?.toLocal(), due);
      expect(stored.title, title);
      expect(NoteRepository(db).byId(note.id)!.rawContent, title);
      if (due?.day == 5) {
        expect(ItemRepository(db).dueOn(clock.now()).map((i) => i.id), [item.id]);
      }
    });
  }

  for (final action in ['capture', 'convert', 'edit', 'toggle', 'close', 'reopen', 'trash']) {
    test('$action活动记录失败时全部回滚，重试只执行一次', () {
      final note = service.capture('原始便签');
      final item = service.lineToItem(note.id, 0);
      if (action == 'reopen') service.close(note.id);
      final before = {for (final table in ['notes', 'items', 'activities'])
        table: db.raw.select('SELECT * FROM $table ORDER BY id')
          .map((r) => r.values.toList()).toList()};
      final run = <String, void Function()>{
        'capture': () => service.capture('新便签'),
        'convert': () => service.lineToItem(note.id, 0),
        'edit': () => service.editContent(note.id, '修改正文'),
        'toggle': () => service.toggleItem(item.id),
        'close': () => service.close(note.id),
        'reopen': () => service.reopen(note.id),
        'trash': () => service.trash(note.id),
      }[action]!;
      db.raw.execute('CREATE TRIGGER fail_activity BEFORE INSERT ON activities '
        "BEGIN SELECT RAISE(ABORT, 'activity failure'); END");
      expect(run, throwsA(predicate((e) => e.toString().contains('activity failure'))));
      for (final table in before.keys) {
        expect(db.raw.select('SELECT * FROM $table ORDER BY id')
          .map((r) => r.values.toList()).toList(), before[table], reason: table);
      }
      db.raw.execute('DROP TRIGGER fail_activity');
      run();
      expect(db.raw.select('SELECT id FROM notes').length, action == 'capture' ? 2 : 1);
      expect(db.raw.select('SELECT id FROM items').length, action == 'convert' ? 2 : 1);
      expect(db.raw.select('SELECT id FROM activities').length,
        before['activities']!.length + 1);
      if (action == 'toggle') expect(ItemRepository(db).byId(item.id)!.isDone, isTrue);
    });
  }

  test('随手记：只要文字就能存，无需标题与时间', () {
    final note = service.capture('回复张三报价\n检查生产 nginx 证书');
    expect(note.id, isNotEmpty);
    expect(note.status, NoteStatus.active);
    expect(note.lines.length, 2);
  });

  test('行转事项：标题取该行，原文不变', () {
    final note = service.capture('回复张三报价\n周五前发周报');
    final item = service.lineToItem(note.id, 0);
    expect(item.title, '回复张三报价');
    expect(item.noteId, note.id);
    expect(service.allItemsDone(note.id), isFalse);
  });

  test('全部事项完成后 allItemsDone 为真', () {
    final note = service.capture('A\nB');
    final a = service.lineToItem(note.id, 0);
    final b = service.lineToItem(note.id, 1);
    service.toggleItem(a.id);
    expect(service.allItemsDone(note.id), isFalse);
    service.toggleItem(b.id);
    expect(service.allItemsDone(note.id), isTrue);
  });

  test('纯文字便签不会被判定为可自动关闭', () {
    final note = service.capture('只是一个想法');
    expect(service.allItemsDone(note.id), isFalse);
  });

  test('关闭与重新打开', () {
    final note = service.capture('A');
    final closed = service.close(note.id);
    expect(closed.isClosed, isTrue);
    expect(service.reopen(note.id).status, NoteStatus.active);
  });

  test('软删除进回收站，30 天后清理', () {
    final note = service.capture('A');
    service.trash(note.id);
    expect(service.purgeTrash(), 0, reason: '刚删除，未到期');
    clock.advance(const Duration(days: 31));
    expect(service.purgeTrash(), 1);
  });
}
