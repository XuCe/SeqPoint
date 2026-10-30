import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'relay_node_fixture.dart';
import 'lan_sync_runtime_epoch_fixture.dart';

void main() {
  test('stale peer checkpoint catches newer author checkpoint after epoch rotation',() async {
    final f=RelayNodeFixture();await f.init();addTearDown(f.close);
    final a=f.runtime.a,b=f.runtime.b,now=DateTime.now().toUtc(),repo=NoteRepository(f.runtime.a.db);
    repo.insert(Note(id:'rotate',kind:NoteKind.text,status:NoteStatus.active,rawContent:'before',createdAt:now,updatedAt:now));
    expect((await a.runtime.syncRelay(f.client(a))).isOk,isTrue);
    expect((await b.runtime.syncRelay(f.client(b))).isOk,isTrue);
    await rotateRuntimePair(f.runtime);
    repo.update(repo.byId('rotate')!.copyWith(rawContent:'after'));
    final advance=await a.runtime.syncRelay(f.client(a));
    expect(advance.isOk,isTrue,reason:advance is Err?'${(advance as Err).cause}':null);
    final recover=await b.runtime.syncRelay(f.client(b));
    expect(recover.isOk,isTrue,reason:recover is Err?'${(recover as Err).cause}':null);
    expect(NoteRepository(b.db).byId('rotate')!.rawContent,'after');
    expect(b.db.raw.select('SELECT covered_seq,key_epoch FROM sync_checkpoints WHERE author=?',[a.keys.deviceId]).single,
      containsPair('key_epoch',2));
  },skip:Platform.environment['SEQPOINT_NODE_BINARY']==null?'Set node binary':false);
}
