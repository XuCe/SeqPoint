import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';
import 'native_sync_support.dart';

Future<void> exchangeLargeMedia(SeqDatabase db,Directory root,String noteId,AcceptanceControl control) async {
  final desktop=control.role=='desktop',peer=desktop?'phone':'desktop';
  final service=AttachmentService(db:db,directory:Directory('${root.path}/attachments'));
  final watch=Stopwatch()..start();
  final bytes=await control.fixture(desktop?'large.png':'large.m4a');
  final attachment=desktop
    ?await service.addImage(bytes,noteId:noteId,name:'large.png')
    :await service.addAudio(bytes,noteId:noteId,name:'large.m4a');
  await control.exchange('${control.role}-attachment',{'id':attachment.id,
    'size':attachment.byteSize,'sha256':attachment.sha256});
  final remote=await control.wait('$peer-attachment') as Map;
  final target=File('${root.path}/attachments/${remote['id']}');
  await until(target.existsSync,seconds:420);
  expect(target.lengthSync(),remote['size']);
  expect(lanSha256(await target.readAsBytes()),remote['sha256']);
  expect(db.raw.select('SELECT * FROM attachments WHERE id=?',[remote['id']]),hasLength(1));
  await control.exchange('${control.role}-files-ready',{'elapsedMs':watch.elapsedMilliseconds,
    'receivedBytes':target.lengthSync(),'sha256':remote['sha256']});
}
