import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late SeqDatabase a, b;
  late ItemRepository first, second;
  late Item original;
  final now = DateTime.utc(2026, 10, 23, 12);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('seqpoint-edit-');
    a = SeqDatabase.open('${dir.path}/test.db')..migrate();
    b = SeqDatabase.open('${dir.path}/test.db')..migrate();
    first = ItemRepository(a);
    second = ItemRepository(b);
    original = first.insert(Item(id: '', title: '原始', status: ItemStatus.todo,
      priority: Priority.p4, source: ItemSource.manual,
      createdAt: now, updatedAt: now, dueAt: now));
  });
  tearDown(() { a.close(); b.close(); dir.deleteSync(recursive: true); });

  for (final field in ['title', 'priority', 'due', 'clear']) {
    test('独立连接同时修改$field时拒绝覆盖且不留下部分修改', () {
      second.update(original.copyWith(title: '其他标题', priority: Priority.p1,
        dueAt: now.add(const Duration(days: 1))));
      final before = b.raw.select('SELECT * FROM items').single.values.toList();
      expect(first.saveEdits(original,
        title: field == 'title' ? '本地标题' : original.title,
        priority: field == 'priority' ? Priority.p0 : original.priority,
        dueAt: field == 'clear' ? null : field == 'due'
          ? now.add(const Duration(days: 2)) : original.dueAt), isFalse);
      expect(b.raw.select('SELECT * FROM items').single.values.toList(), before);
    });
  }
  test('相同修改允许保存，已删除事项不能被编辑恢复', () {
    second.update(original.copyWith(title: '一致', clearDueAt: true));
    expect(first.saveEdits(original, title: '一致', priority: original.priority,
      dueAt: null), isTrue);
    second.update(second.byId(original.id)!.copyWith(deletedAt: now));
    expect(() => first.saveEdits(original, title: '恢复',
      priority: original.priority, dueAt: original.dueAt), throwsStateError);
    expect(second.byId(original.id)!.deletedAt, now);
    expect(second.byId(original.id)!.title, '一致');
  });
  test('另一个连接持有写锁时保存失败，解除后重试只保留一条事项', () {
    b.raw.execute('BEGIN IMMEDIATE');
    try {
      expect(() => first.saveEdits(original, title: '修改',
        priority: original.priority, dueAt: original.dueAt), throwsA(anything));
      expect(second.byId(original.id)!.title, original.title);
    } finally { b.raw.execute('ROLLBACK'); }
    expect(first.saveEdits(original, title: '修改', priority: original.priority,
      dueAt: original.dueAt), isTrue);
    expect(second.openAll().single.title, '修改');
  });

  test('独立数据库连接合并修改并在重新打开后保留全部字段', () {
    second.update(original.copyWith(dueAt: now.add(const Duration(days: 1)),
      priority: Priority.p1, status: ItemStatus.done, completedAt: now));
    expect(first.saveEdits(original, title: '新标题', priority: original.priority,
      dueAt: original.dueAt!.toLocal()), isTrue);
    final saved = second.byId(original.id)!;
    expect(saved.title, '新标题');
    expect(saved.priority, Priority.p1);
    expect(saved.dueAt, now.add(const Duration(days: 1)));
    expect(saved.completedAt, now);
    expect(saved.status, ItemStatus.done);
    final snapshot = a.raw.select('SELECT * FROM items').single.values.toList();
    a.close(); b.close();
    a = SeqDatabase.open('${dir.path}/test.db')..migrate();
    b = SeqDatabase.open('${dir.path}/test.db')..migrate();
    expect(b.raw.select('SELECT * FROM items').single.values.toList(), snapshot);
  });
}
