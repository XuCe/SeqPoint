import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('保存失败对另一连接不可见，重启后重试只有一份便签及活动', () {
    final dir = Directory.systemTemp.createTempSync('seqpoint-transaction-');
    var db = SeqDatabase.open('${dir.path}/test.db')..migrate();
    var observer = SeqDatabase.open('${dir.path}/test.db')..migrate();
    NoteService service() => NoteService(db: db, notes: NoteRepository(db),
      items: ItemRepository(db), activities: ActivityRepository(db));
    addTearDown(() { db.close(); observer.close(); dir.deleteSync(recursive: true); });
    db.raw.execute('CREATE TRIGGER fail_activity BEFORE INSERT ON activities '
      "BEGIN SELECT RAISE(ABORT, 'activity failure'); END");
    expect(() => service().capture('重试内容'), throwsA(anything));
    expect(observer.raw.select('SELECT id FROM notes'), isEmpty);
    expect(observer.raw.select('SELECT id FROM activities'), isEmpty);
    db.close(); observer.close();
    db = SeqDatabase.open('${dir.path}/test.db')..migrate();
    observer = SeqDatabase.open('${dir.path}/test.db')..migrate();
    expect(observer.raw.select('SELECT id FROM notes'), isEmpty);
    expect(observer.raw.select('SELECT id FROM activities'), isEmpty);
    db.raw.execute('DROP TRIGGER fail_activity');
    final note = service().capture('重试内容');
    expect(NoteRepository(observer).active().single.rawContent, '重试内容');
    expect(ActivityRepository(observer).forObject('note', note.id), hasLength(1));
    db.close(); observer.close();
    db = SeqDatabase.open('${dir.path}/test.db')..migrate();
    observer = SeqDatabase.open('${dir.path}/test.db')..migrate();
    expect(NoteRepository(observer).active().single.id, note.id);
    expect(ActivityRepository(observer).recent(), hasLength(1));
  });
}
