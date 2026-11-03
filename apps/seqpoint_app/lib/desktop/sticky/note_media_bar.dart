import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../features/attachments/attachment_panel.dart';
import '../../features/meetings/meeting_panel.dart';
import '../../theme/seq_tokens.dart';

class NoteMediaBar extends StatelessWidget {
  const NoteMediaBar({super.key, required this.noteId, this.leading = const [],
    this.beforeMeeting, this.onChanged});

  final String noteId;
  final List<Widget> leading;
  final VoidCallback? beforeMeeting;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final db = scope.database;
    Widget images(bool compact) => AttachmentPanel(database: db!, noteId: noteId,
        enabled: !scope.restoring, actionOnly: compact);
    Widget audio(bool compact) => MeetingPanel(database: db!, noteId: noteId,
        noteService: scope.noteService, enabled: !scope.restoring, actionOnly: compact,
        beforeOpen: beforeMeeting, onChanged: onChanged);
    return Container(
      height: 40, padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x187A6620)))),
      child: IconButtonTheme(
        data: IconButtonThemeData(style: IconButton.styleFrom(iconSize: 18,
            foregroundColor: SeqTokens.noteInk, minimumSize: const Size(32, 32),
            padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap)),
        child: Row(children: [
          Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal,
            child: Row(children: [...leading, if (db != null) ...[images(true), audio(true)]]))),
          if (db != null)
            IconButton(tooltip: '管理附件与转写', icon: const Icon(Icons.folder_open_outlined),
              onPressed: () => showModalBottomSheet<void>(context: context,
                isScrollControlled: true, showDragHandle: true,
                builder: (_) => FractionallySizedBox(heightFactor: 0.72, child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16), children: [images(false), audio(false)])))),
        ]),
      ),
    );
  }
}
