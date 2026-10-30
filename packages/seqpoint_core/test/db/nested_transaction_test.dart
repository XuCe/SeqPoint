import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  setUp(() {
    db = SeqDatabase.inMemory();
    db.raw.execute('CREATE TABLE probe(id INTEGER PRIMARY KEY)');
  });
  tearDown(() => db.close());
  void write(int id) => db.raw.execute('INSERT INTO probe(id) VALUES (?)', [id]);
  List<int> ids() => db.raw.select('SELECT id FROM probe ORDER BY id')
      .map((r) => r['id'] as int).toList();
  test('三层嵌套成功且返回原结果', () {
    final result = db.transaction(() {
      write(1);
      return db.transaction(() => db.transaction(() { write(2); return 7; }));
    });
    expect(result, 7);
    expect(ids(), [1, 2]);
  });
  test('内层成功不提前提交，外层失败全部回滚', () {
    expect(() => db.transaction(() {
      write(1);
      db.transaction(() => write(2));
      throw StateError('outer');
    }), throwsStateError);
    expect(ids(), isEmpty);
  });
  test('内层失败可由外层处理，仅回滚内层', () {
    db.transaction(() {
      write(1);
      try { db.transaction(() { write(2); throw StateError('inner'); }); }
      on StateError { write(3); }
    });
    expect(ids(), [1, 3]);
  });
  test('已有调用方事务不被内层提交', () {
    db.raw.execute('BEGIN');
    db.transaction(() => write(1));
    db.raw.execute('ROLLBACK');
    expect(ids(), isEmpty);
  });
}
