import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late OrganizeProposal proposal;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    TagRepository(db).ensureBuiltins();
    final now = DateTime.utc(2026, 10, 25);
    NoteRepository(db).insert(Note(id: 'note', kind: NoteKind.text,
        status: NoteStatus.active, rawContent: '原始行', createdAt: now, updatedAt: now));
    proposal = OrganizeProposal(noteId: 'note', sourceContent: '原始行', items: const [
      ProposedItem(id: 'candidate', title: '候选', lineIndex: 0,
          projectTagName: '项目A', typeTagName: '沟通')]);
    db.raw.execute("UPDATE sync_local SET enabled = 1, device_id = 'pc'");
  });
  tearDown(() => db.close());
  test('AI采纳两种关联同事务捕获，重复采纳不重复记录', () {
    final applier = OrganizeApplier(db);
    expect(applier.apply(proposal), hasLength(1));
    final links = db.raw.select("SELECT * FROM sync_operations WHERE object_type = 'item_tag' AND field = 'present'");
    expect(links, hasLength(2));
    expect(ItemRepository(db).tagIdsOf('candidate'), hasLength(2));
    final count = db.raw.select('SELECT count(*) AS n FROM sync_operations').single['n'];
    expect(applier.apply(proposal), isEmpty);
    expect(db.raw.select('SELECT count(*) AS n FROM sync_operations').single['n'], count);
    expect(NoteRepository(db).byId('note')!.rawContent, '原始行');
  });
  test('关联操作失败回滚整个采纳：事项/新标签/关联/活动/HLC', () {
    db.raw.execute('CREATE TEMP TRIGGER reject_ai_link BEFORE INSERT ON sync_operations '
        "WHEN NEW.object_type = 'item_tag' AND NEW.field = 'present' "
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => OrganizeApplier(db).apply(proposal), throwsA(isA<SqliteException>()));
    expect(db.raw.select('SELECT * FROM items'), isEmpty);
    expect(TagRepository(db).byName('项目A', TagKind.project), isNull);
    expect(db.raw.select('SELECT * FROM item_tags'), isEmpty);
    expect(db.raw.select('SELECT * FROM activities'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
  });
}
