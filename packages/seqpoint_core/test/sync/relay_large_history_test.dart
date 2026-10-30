import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'legacy_history_fixture.dart';
import 'relay_node_fixture.dart';

void main() {
  test('more than 64 MiB and 1000 legacy segments compact and continue syncing',() async {
    final f=RelayNodeFixture();await f.init();addTearDown(f.close);
    final a=f.runtime.a,b=f.runtime.b;
    final expected=await seedLegacyHistory(a);
    final old=a.db.raw.select('SELECT COUNT(*) AS n,SUM(length(segment_bytes)) AS bytes FROM sync_publications').single;
    expect(old['n'],greaterThan(1000));expect(old['bytes'],greaterThan(64*1024*1024));
    final up=await a.runtime.syncRelay(f.client(a));
    expect(up.isOk,isTrue,reason:up is Err?'${(up as Err).cause}':null);
    expect(a.db.raw.select('SELECT * FROM sync_publications'),hasLength(1));
    expect(a.db.raw.select('SELECT COUNT(*) AS n FROM sync_operations').single['n'],lessThan(30));
    final down=await b.runtime.syncRelay(f.client(b));
    expect(down.isOk,isTrue,reason:down is Err?'${(down as Err).cause}':null);
    expect(NoteRepository(b.db).byId('long-history')!.rawContent,expected);
    final repo=NoteRepository(a.db);repo.update(repo.byId('long-history')!.copyWith(rawContent:'continues'));
    expect((await a.runtime.syncRelay(f.client(a))).isOk,isTrue);
    expect((await b.runtime.syncRelay(f.client(b))).isOk,isTrue);
    expect(NoteRepository(b.db).byId('long-history')!.rawContent,'continues');
    final usage=f.client(a);addTearDown(usage.close);
    expect((await usage.usedBytes() as Ok<int>).value,lessThan(1024*1024));
  },timeout:const Timeout(Duration(minutes:3)),
    skip:Platform.environment['SEQPOINT_NODE_BINARY']==null?'Set node binary':false);
}
