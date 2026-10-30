import 'dart:io';
import 'dart:typed_data';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/identity/membership_state.dart' as membership;
import 'package:test/test.dart';
import 'relay_node_fixture.dart';

void main() {
  test('revoked owner media is re-published by a holder without blocking text',() async {
    final f=RelayNodeFixture();await f.init();addTearDown(f.close);
    final a=f.runtime.a,b=f.runtime.b,now=DateTime.now().toUtc();
    NoteRepository(b.db).insert(Note(id:'revoke-media',kind:NoteKind.text,status:NoteStatus.active,
      rawContent:'retained',createdAt:now,updatedAt:now));
    AttachmentSyncPolicy(a.db).setEnabled(true);AttachmentSyncPolicy(b.db).setEnabled(true);
    final source=AttachmentService(db:b.db,directory:Directory('${b.directory.path}/attachments'));
    final bytes=Uint8List.fromList([137,80,78,71,13,10,26,10,...List.filled(100,42)]);
    final photo=await source.addImage(bytes,noteId:'revoke-media');
    final unavailable=await source.addImage(bytes,noteId:'revoke-media');
    expect((await b.runtime.syncRelay(f.client(b))).isOk,isTrue);
    expect((await a.runtime.syncRelay(f.client(a))).isOk,isTrue);
    await File('${a.directory.path}/attachments/${unavailable.id}').delete();
    final nextKey=VaultKey(epoch:2,keyBytes:List.filled(32,71));
    final event=await membership.MembershipEvent.create(parent:a.membership.state,issuer:a.keys,
      type:membership.MembershipEventType.revoke,targetDeviceId:b.keys.deviceId,epochKey:nextKey);
    final path='members/${a.keys.deviceId}.json';
    final old=MembershipFile.decode(a.controls[path]!,issuerFileDeviceId:a.keys.deviceId,
      expectedVaultPublicId:a.membership.state.vaultPublicId,expectedAuthorityId:a.membership.state.authorityId);
    final control=MembershipFile(vaultPublicId:old.vaultPublicId,authorityId:old.authorityId,
      issuerDeviceId:a.keys.deviceId,events:[...old.events,event]).encode();
    a.controls[path]=control;
    a.historicalKeys[a.epochKey.epoch]=a.epochKey.keyBytes;
    await a.ingest(path,control);a.epochKey=nextKey;
    final result=await a.runtime.syncRelay(f.client(a));
    expect(result.isOk,isTrue,reason:result is Err?'${(result as Err).cause}':null);
    expect(a.db.raw.select('SELECT content_owner FROM attachments WHERE id=?',[photo.id]).single['content_owner'],a.keys.deviceId);
    expect(await File('${a.directory.path}/attachments/${photo.id}').readAsBytes(),bytes);
    expect(a.runtime.mediaPending,isTrue);
    expect(NoteRepository(a.db).byId('revoke-media')!.rawContent,'retained');
  },skip:Platform.environment['SEQPOINT_NODE_BINARY']==null?'Set node binary':false);
  test('image and original audio cross offline devices without lossy conversion',() async {
    final f=RelayNodeFixture(); await f.init(); addTearDown(f.close);
    final a=f.runtime.a,b=f.runtime.b,now=DateTime.now().toUtc();
    NoteRepository(a.db).insert(Note(id:'media',kind:NoteKind.text,status:NoteStatus.active,
      rawContent:'files',createdAt:now,updatedAt:now));
    AttachmentSyncPolicy(a.db).setEnabled(true);
    AttachmentSyncPolicy(b.db).setEnabled(true);
    final source=AttachmentService(db:a.db,directory:Directory('${a.directory.path}/attachments'));
    final image=Uint8List.fromList([137,80,78,71,13,10,26,10,...List.filled(1200000,42)]);
    final audio=Uint8List.fromList([0,0,0,24,...'ftypM4A '.codeUnits,...List.filled(1600000,17)]);
    final photo=await source.addImage(image,noteId:'media');
    final recording=await source.addAudio(audio,noteId:'media');
    final up=await a.runtime.syncRelay(f.client(a)); expect(up.isOk,isTrue,reason:up is Err?'${(up as Err).cause}':null);
    await a.runtime.pause(); await f.stop(); await f.start();
    final down=await b.runtime.syncRelay(f.client(b)); expect(down.isOk,isTrue,reason:down is Err?'${(down as Err).cause}':null);
    expect(await File('${b.directory.path}/attachments/${photo.id}').readAsBytes(),image);
    expect(await File('${b.directory.path}/attachments/${recording.id}').readAsBytes(),audio);
    final retry=await b.runtime.syncRelay(f.client(b)); expect(retry.isOk,isTrue);
  },skip:Platform.environment['SEQPOINT_NODE_BINARY']==null?'Set node binary':false);
}
