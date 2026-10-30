import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

class MeetingAudioPage extends StatefulWidget {
  const MeetingAudioPage({
    super.key,
    required this.attachments,
    required this.recording,
    this.player,
    this.save,
  });
  final AttachmentService attachments;
  final Attachment recording;
  final AudioPlayer? player;
  final Future<String?> Function({
    required String fileName,
    required Uint8List bytes,
  })?
  save;
  @override
  State<MeetingAudioPage> createState() => _MeetingAudioPageState();
}

class _MeetingAudioPageState extends State<MeetingAudioPage>
    with WidgetsBindingObserver {
  late final AudioPlayer _player;
  StreamSubscription<PlayerState>? _states;
  PlayerState _state = PlayerState.stopped;
  Attachment? _loadedRecording;
  AttachmentService? _loadedAttachments;
  bool _busy = false;
  bool _stopping = false;
  int _generation = 0;
  String? _message;
  bool _foreground = true;

  bool _current(int generation) =>
      mounted && generation == _generation && _foreground;
  bool get _hasCurrentSource =>
      identical(_loadedRecording, widget.recording) &&
      identical(_loadedAttachments, widget.attachments);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = widget.player ?? AudioPlayer();
    _states = _player.onPlayerStateChanged.listen(
      (state) {
        if (mounted) setState(() => _state = state);
      },
      onError: (Object _) {
        if (mounted) setState(() => _message = '本机录音播放中断，请重试');
      },
    );
  }

  @override
  void didUpdateWidget(MeetingAudioPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recording != widget.recording ||
        oldWidget.attachments != widget.attachments) {
      unawaited(_stop());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) unawaited(_stop());
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_states?.cancel());
    unawaited(
      _player.dispose().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'meeting audio disposal',
          ),
        );
      }),
    );
    super.dispose();
  }

  Future<void> _run(Future<void> Function(int) action, String error) async {
    if (_busy || _stopping || !_foreground) return;
    final recordingId = widget.recording.id;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action(generation);
    } catch (_) {
      if (mounted && widget.recording.id == recordingId) {
        setState(() => _message = error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<File> _file() async {
    final recording = widget.recording;
    if (recording.media != 'audio' || recording.mime != 'audio/mp4') {
      throw StateError('不是会议录音');
    }
    final file = await widget.attachments.file(recording.id);
    final size = await file.length();
    if (size == 0 ||
        size > AttachmentService.maxAudioBytes ||
        size != recording.byteSize) {
      throw StateError('录音文件大小不符');
    }
    return file;
  }

  Future<void> _play() => _run((generation) async {
    final resume = _state == PlayerState.paused && _hasCurrentSource;
    final recording = widget.recording;
    final attachments = widget.attachments;
    _loadedRecording = null;
    _loadedAttachments = null;
    if (resume) {
      await _player.resume();
    } else {
      final file = await _file();
      if (!_current(generation)) return;
      await _player.play(DeviceFileSource(file.path, mimeType: 'audio/mp4'));
    }
    if (_current(generation)) {
      _loadedRecording = recording;
      _loadedAttachments = attachments;
    } else if (mounted) {
      await _player.stop();
    }
  }, '无法播放本机录音，请确认文件仍在此设备');

  Future<void> _stop() async {
    final generation = ++_generation;
    _loadedRecording = null;
    _loadedAttachments = null;
    if (_stopping) return;
    setState(() => _stopping = true);
    try {
      await _player.stop();
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _message = '停止播放失败，请关闭此页面重试');
      }
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  Future<void> _export() => _run((generation) async {
    final recordingId = widget.recording.id;
    final file = await _file();
    if (!_current(generation)) return;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (!_current(generation)) return;
      if (bytes.length + chunk.length > AttachmentService.maxAudioBytes) {
        throw StateError('录音超过导出大小限制');
      }
      bytes.add(chunk);
    }
    if (!_current(generation)) return;
    if (bytes.length != widget.recording.byteSize) {
      throw StateError('录音文件大小不符');
    }
    final fileName = 'seqpoint-recording-${newId()}.m4a';
    final audio = bytes.takeBytes();
    final save = widget.save;
    final result = save == null
        ? await _save(generation, fileName: fileName, bytes: audio)
        : await save(fileName: fileName, bytes: audio);
    if (mounted && widget.recording.id == recordingId) {
      setState(() => _message = result == null ? '已取消导出' : '录音已交由系统保存');
    }
  }, '录音导出失败，原文件已保留');

  Future<String?> _save(
    int generation, {
    required String fileName,
    required Uint8List bytes,
  }) async {
    // file_picker 11 在 iOS 文档目录暂存导出副本，结束后仅清理本次副本。
    File? copy;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final directory = await getApplicationDocumentsDirectory();
      if (!_current(generation)) return null;
      copy = File('${directory.path}/$fileName');
      final exists = await copy.exists();
      if (!_current(generation)) return null;
      if (exists) throw StateError('导出副本已存在');
    }
    if (!_current(generation)) return null;
    String? destination;
    try {
      destination = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: ['m4a'],
      );
      return destination;
    } finally {
      if (copy != null &&
          await copy.exists() &&
          (destination == null ||
              (destination != copy.path &&
                  !await FileSystemEntity.identical(copy.path, destination)))) {
        await copy.delete();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('会议录音')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.recording.fileName ?? '会议录音'),
          const Text('录音仅保存在此设备，导出时由你选择保存位置。'),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy || _stopping
                    ? null
                    : _hasCurrentSource && _state == PlayerState.playing
                    ? () => _run((_) => _player.pause(), '暂停播放失败，请重试')
                    : _play,
                icon: Icon(
                  _hasCurrentSource && _state == PlayerState.playing
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
                label: Text(
                  _hasCurrentSource && _state == PlayerState.playing
                      ? '暂停'
                      : _hasCurrentSource && _state == PlayerState.paused
                      ? '继续播放'
                      : '播放',
                ),
              ),
              TextButton(
                onPressed: _stopping ? null : _stop,
                child: const Text('停止'),
              ),
              TextButton.icon(
                onPressed: _busy || _stopping ? null : _export,
                icon: const Icon(Icons.save_alt),
                label: const Text('导出录音'),
              ),
            ],
          ),
          if (_busy || _stopping) const LinearProgressIndicator(),
          if (_message != null) Text(_message!),
        ],
      ),
    ),
  );
}
