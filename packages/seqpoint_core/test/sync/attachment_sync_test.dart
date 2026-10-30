import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

List<Operation> facts(SeqDatabase db) => db.raw
    .select('SELECT * FROM sync_operations')
    .map(
      (r) => Operation(
        opId: r['op_id'] as String,
        deviceId: r['device_id'] as String,
        hlc: Hlc(
          millis: r['hlc_millis'] as int,
          counter: r['hlc_counter'] as int,
          deviceId: r['device_id'] as String,
        ),
        objectType: r['object_type'] as String,
        objectId: r['object_id'] as String,
        field: r['field'] as String,
        value: jsonDecode(r['value_json'] as String),
      ),
    )
    .toList();
void main() {
  test('private media stays local; enabled creation/deletion projects after parent arrives', () async {
    final a = SeqDatabase.inMemory()..migrate(),
        b = SeqDatabase.inMemory()..migrate();
    addTearDown(a.close);
    addTearDown(b.close);
    SyncBaseline(a).initialize('a' * 43);
    SyncBaseline(b).initialize('b' * 43);
    final root = await Directory.systemTemp.createTemp('media-sync-');
    addTearDown(() => root.delete(recursive: true));
    final service = AttachmentService(db: a, directory: root);
    final now = DateTime.now().toUtc();
    NoteRepository(a).insert(
      Note(
        id: 'n',
        kind: NoteKind.text,
        status: NoteStatus.active,
        rawContent: 'media',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0]);
    final private = await service.addImage(bytes, noteId: 'n');
    expect(facts(a).where((op) => op.objectId == private.id), isEmpty);
    AttachmentSyncPolicy(a).setEnabled(true, includeExisting: false);
    final shared = await service.addImage(bytes, noteId: 'n');
    final media = facts(a).where((op) => op.objectId == shared.id).toList();
    expect(media, isNotEmpty);
    SyncInbox(b).storeVerifiedBatch(peerId: 'a' * 43, operations: media);
    expect(SyncProjector(b).project(), greaterThan(0));
    SyncInbox(b).storeVerifiedBatch(
      peerId: 'a' * 43,
      operations: facts(a).where((op) => op.objectType == 'note').toList(),
    );
    expect(SyncProjector(b).project(), 0);
    expect(
      b.raw.select('SELECT sha256 FROM attachments WHERE id=?', [
        shared.id,
      ]).single['sha256'],
      shared.sha256,
    );
    await service.remove(shared.id);
    SyncInbox(b).storeVerifiedBatch(
      peerId: 'a' * 43,
      operations: facts(a).where((op) => op.objectId == shared.id).toList(),
    );
    SyncProjector(b).project();
    expect(
      b.raw.select('SELECT deleted_at FROM attachments WHERE id=?', [
        shared.id,
      ]).single['deleted_at'],
      isNotNull,
    );
  });
  test('explicit opt-in captures existing files once and disabling keeps new files private', () async {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    final root = await Directory.systemTemp.createTemp('media-opt-in-');
    addTearDown(() => root.delete(recursive: true));
    final now = DateTime.now().toUtc();
    NoteRepository(db).insert(
      Note(
        id: 'n',
        kind: NoteKind.text,
        status: NoteStatus.active,
        rawContent: 'media',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final service = AttachmentService(db: db, directory: root);
    final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0]);
    final old = await service.addImage(bytes, noteId: 'n');
    SyncBaseline(db).initialize('a' * 43);
    expect(facts(db).where((op) => op.objectType == 'attachment'), isEmpty);
    final policy = AttachmentSyncPolicy(db)..setEnabled(true);
    final initial = facts(db).where((op) => op.objectId == old.id).length;
    expect(initial, greaterThan(0));
    policy.setEnabled(true);
    expect(facts(db).where((op) => op.objectId == old.id).length, initial);
    policy.setEnabled(false);
    final private = await service.addImage(bytes, noteId: 'n');
    expect(facts(db).where((op) => op.objectId == private.id), isEmpty);
  });
}
