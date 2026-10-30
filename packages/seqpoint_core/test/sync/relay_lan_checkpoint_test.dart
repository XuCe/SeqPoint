import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'relay_node_fixture.dart';

void main() {
  test('cloud history GC still allows offline peer to recover over LAN only',() async {
    final f=RelayNodeFixture();await f.init();addTearDown(f.close);
    final a=f.runtime.a,b=f.runtime.b,now=DateTime.now().toUtc();
    final repo=NoteRepository(a.db);
    repo.insert(Note(id:'compact',kind:NoteKind.text,status:NoteStatus.active,
      rawContent:'first',createdAt:now,updatedAt:now));
    for(var i=0;i<3;i++) {
      repo.update(repo.byId('compact')!.copyWith(rawContent:'version $i'));
      final result=await a.runtime.syncRelay(f.client(a));
      expect(result.isOk,isTrue,reason:result is Err?'${(result as Err).cause}':null);
    }
    expect(a.db.raw.select('SELECT * FROM sync_publications'),hasLength(1));
    expect(a.db.raw.select('SELECT local_floor FROM sync_checkpoints WHERE author=?',[a.keys.deviceId]).single['local_floor'],2);
    await f.stop();await f.runtime.start();
    final result=await b.runtime.syncOnce(f.runtime.peer(a));
    expect(result.isOk,isTrue,reason:result is Err?'${(result as Err).cause}':null);
    expect(NoteRepository(b.db).byId('compact')!.rawContent,'version 2');
    expect(SyncSegmentReceiver(b.db).committedWatermarks[a.keys.deviceId],3);
    repo.update(repo.byId('compact')!.copyWith(rawContent:'LAN later'));
    expect((await a.runtime.syncOnce(f.runtime.peer(b))).isOk,isTrue);
    expect((await b.runtime.syncOnce(f.runtime.peer(a))).isOk,isTrue);
    expect(NoteRepository(b.db).byId('compact')!.rawContent,'LAN later');
  },skip:Platform.environment['SEQPOINT_NODE_BINARY']==null?'Set node binary':false);
}
