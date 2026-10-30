import 'dart:async';
import 'dart:typed_data';

import 'package:seqpoint_core/seqpoint_core.dart';

class PausedAttachments extends AttachmentService {
  PausedAttachments({required super.db, required super.directory});
  final reached = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Attachment> addAudio(Uint8List bytes, {required String noteId,
    String? name, bool Function()? canCommit}) async {
    reached.complete();
    await release.future;
    return super.addAudio(bytes, noteId: noteId, name: name, canCommit: canCommit);
  }
}
