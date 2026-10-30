import 'dart:convert';
import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/sync/sync_checkpoint_facts.dart';
import 'lan_sync_runtime_fixture.dart';

Future<String> seedLegacyHistory(RuntimeNode node,{int edits=1001}) async {
  final db=node.db,now=DateTime.now().toUtc(),id=node.keys.deviceId;
  NoteRepository(db).insert(Note(id:'long-history',kind:NoteKind.text,status:NoteStatus.active,
    rawContent:'initial',createdAt:now,updatedAt:now));
  final base=db.raw.select('SELECT * FROM sync_operations').map(checkpointOperation).toList();
  final directory=Directory('${node.directory.path}/vault/ops/$id')..createSync(recursive:true);
  final millis=DateTime.now().millisecondsSinceEpoch;
  var last='';
  for(var seq=1;seq<=edits+1;seq++) {
    final List<Operation> operations;
    if(seq==1) {operations=base;} else {
      last='${'history '*9000}$seq';
      final op=Operation(opId:'$id:legacy:$seq',deviceId:id,hlc:Hlc(millis:millis,counter:10000+seq,deviceId:id),
        objectType:'note',objectId:'long-history',field:'raw_content',value:last);
      db.raw.execute('INSERT INTO sync_operations '
        '(op_id,device_id,hlc_millis,hlc_counter,object_type,object_id,field,value_json,source) VALUES (?,?,?,?,?,?,?,?,?)',
        [op.opId,id,millis,10000+seq,op.objectType,op.objectId,op.field,jsonEncode(last),'local']);
      operations=[op];
    }
    final header=Segment(deviceId:id,keyEpoch:node.epochKey.epoch,seq:seq,opCount:operations.length,
      createdAt:now,sealed:true,payload:const []);
    final aad=header.authenticatedHeader(node.membership.state.vaultPublicId);
    final payload=await XChaCha20Aead().seal(utf8.encode(jsonEncode(operations.map((o)=>o.toJson()).toList())),node.epochKey.keyBytes,aad:aad);
    final bytes=header.withPayload(payload,signature:await node.keys.signer.sign([...aad,...payload])).encode();
    final name=VaultLayout.segmentName(now.year,now.month,seq);
    db.transaction(() {
      db.raw.execute('INSERT INTO sync_publications(seq,file_name,key_epoch,segment_bytes,sealed,published) VALUES (?,?,?,?,?,?)',[seq,name,node.epochKey.epoch,bytes,1,1]);
      for(final op in operations) {db.raw.execute('UPDATE sync_operations SET publication_seq=? WHERE op_id=?',[seq,op.opId]);}
    });
    await File('${directory.path}/$name').writeAsBytes(bytes);
  }
  db.raw.execute('UPDATE sync_local SET hlc_millis=?,hlc_counter=? WHERE id=1',[millis,10000+edits+1]);
  SyncProjector(db).project();return last;
}
