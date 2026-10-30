import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import 'meeting_recording_page.dart';
import 'meeting_audio_page.dart';
import 'meeting_transcript_page.dart';
import 'recording_session.dart';
import '../../app/app_scope.dart';

class MeetingPanel extends StatefulWidget {
  const MeetingPanel({
    super.key,
    required this.database,
    required this.noteId,
    required this.noteService,
    this.enabled = true,
    this.beforeOpen,
    this.onChanged,
    this.service,
  });
  final SeqDatabase database;
  final String noteId;
  final NoteService noteService;
  final bool enabled;
  final FutureOr<void> Function()? beforeOpen;
  final VoidCallback? onChanged;
  final AttachmentService? service;
  @override
  State<MeetingPanel> createState() => _MeetingPanelState();
}

class _MeetingPanelState extends State<MeetingPanel> {
  AttachmentService? _service;
  List<Attachment> _recordings = [];
  bool _busy = false;
  String? _error;
  int _generation = 0;
  int? _syncRevision;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revision=context.dependOnInheritedWidgetOfExactType<AppScope>()?.syncRevision;
    if(_syncRevision!=null && revision!=_syncRevision && _service!=null) {
      _recordings=_service!.list(noteId:widget.noteId,media:'audio');
    }
    _syncRevision=revision;
  }
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MeetingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.database != widget.database ||
        oldWidget.noteId != widget.noteId ||
        oldWidget.service != widget.service) {
      _load();
    }
  }

  bool _current(int generation) => mounted && generation == _generation;

  Future<void> _load() async {
    final generation = ++_generation;
    final noteId = widget.noteId;
    final database = widget.database;
    _service = null;
    _recordings = [];
    _busy = false;
    _error = null;
    try {
      final service =
          widget.service ??
          AttachmentService(
            db: database,
            directory: Directory(
              '${(await getApplicationSupportDirectory()).path}/attachments',
            ),
          );
      if (!_current(generation)) return;
      setState(() {
        _service = service;
        _recordings = service.list(noteId: noteId, media: 'audio');
      });
    } catch (_) {
      if (_current(generation)) setState(() => _error = '无法读取本机录音，请重试');
    }
  }

  Future<void> _open(bool recording) async {
    if (_busy || !widget.enabled || _service == null) return;
    final database = widget.database;
    final generation = _generation;
    final noteId = widget.noteId;
    final service = _service!;
    final notes = widget.noteService;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.beforeOpen?.call();
      if (!_current(generation) || !widget.enabled) return;
      final session = recording
          ? RecordingSession(
              attachments: service,
              noteId: noteId,
              temporaryDirectory: await getTemporaryDirectory(),
            )
          : null;
      if (!_current(generation) || !widget.enabled) {
        await session?.dispose();
        return;
      }
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => session == null
              ? MeetingTranscriptPage(
                  database: database,
                  noteId: noteId,
                  noteService: notes,
                )
              : MeetingRecordingPage(session: session),
        ),
      );
      if (_current(generation) && saved == true) {
        widget.onChanged?.call();
        await _load();
      }
    } catch (_) {
      if (_current(generation)) setState(() => _error = '无法打开会议功能，请先保存便签后重试');
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Attachment recording) async {
    if (_busy || !widget.enabled || _service == null) return;
    final generation = _generation;
    setState(() => _busy = true);
    try {
      await _service!.remove(recording.id);
      if (_current(generation)) await _load();
    } catch (_) {
      if (_current(generation)) setState(() => _error = '无法移除录音，请重试');
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _listen(Attachment recording) async {
    if (_busy || !widget.enabled || _service == null) return;
    final generation = _generation, service = _service!;
    setState(() => _busy = true);
    try {
      final file=await service.file(recording.id);
      if(!_current(generation)) return;
      if(!file.existsSync()) {
        setState(()=>_error=recording.isShared?'原文件尚未下载，请等待同步后重试':'本机录音文件缺失');
        return;
      }
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => MeetingAudioPage(attachments: service, recording: recording)));
    } catch (_) {
      if (_current(generation)) setState(() => _error = '无法打开本机录音，请重试');
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy || !widget.enabled || _service == null
                  ? null
                  : () => _open(true),
              icon: const Icon(Icons.mic_none),
              label: const Text('会议录音'),
            ),
            TextButton.icon(
              onPressed: _busy || !widget.enabled || _service == null
                  ? null
                  : () => _open(false),
              icon: const Icon(Icons.text_snippet_outlined),
              label: const Text('导入转写'),
            ),
          ],
        ),
        const Text('录音仅本机保存，点开可播放或另存；转写文字需另行导入。移除后保留原文件供本机恢复。'),
        if (_error != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              if (_service == null)
                TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        for (final recording in _recordings)
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: _busy || !widget.enabled ? null : () => _listen(recording),
            leading: const Icon(Icons.audio_file_outlined),
            title: Text(recording.fileName ?? '会议录音'),
            subtitle: Text(
              '${(recording.byteSize / 1024).toStringAsFixed(1)} KB · ${recording.isShared?'原文件同步':'仅本机'}',
            ),
            trailing: IconButton(
              tooltip: '移除录音',
              onPressed: _busy || !widget.enabled
                  ? null
                  : () => _remove(recording),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
      ],
    ),
  );
}
