import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

/// 前台录音会话：只有用户停止并保存后才建立附件记录。
class RecordingSession {
  RecordingSession({
    required this.attachments,
    required this.noteId,
    required this.temporaryDirectory,
    AudioRecorder? recorder,
  }) : _recorder = recorder ?? AudioRecorder();
  final AttachmentService attachments;
  final String noteId;
  final Directory temporaryDirectory;
  final AudioRecorder _recorder;
  Directory? _working;
  String? _path;
  bool recording = false;
  bool busy = false;
  bool _closed = false;
  int _generation = 0;
  Future<void>? _canceling;
  bool get hasDraft => _path != null;

  bool _current(int generation) => !_closed && generation == _generation;
  Future<void> start() async {
    if (_closed || busy || recording || hasDraft) throw StateError('录音会话不可开始');
    final generation = ++_generation;
    busy = true;
    try {
      attachments.list(noteId: noteId, media: 'audio');
      if (!await _recorder.hasPermission()) throw StateError('麦克风权限未授予');
      if (!_current(generation)) return;
      final working = await temporaryDirectory.createTemp('seqpoint-meeting-');
      if (!_current(generation)) {
        await working.delete(recursive: true);
        return;
      }
      _working = working;
      _path = '${working.path}/recording.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 96000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: _path!,
      );
      if (!_current(generation)) {
        await _recorder.cancel();
        return;
      }
      recording = true;
    } catch (_) {
      await _cleanup();
      rethrow;
    } finally {
      if (_current(generation)) busy = false;
    }
  }

  Future<Attachment> save() async {
    if (_closed || busy || _path == null) throw StateError('没有可保存的录音');
    final generation = _generation;
    busy = true;
    try {
      if (recording) {
        final stopped = await _recorder.stop();
        if (stopped != _path) throw StateError('录音文件不可用');
        recording = false;
      }
      if (!_current(generation)) throw StateError('录音已取消');
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in File(_path!).openRead()) {
        if (!_current(generation)) throw StateError('录音已取消');
        if (bytes.length + chunk.length > AttachmentService.maxAudioBytes) {
          throw StateError('录音超过 50 MB，请缩短后重试');
        }
        bytes.add(chunk);
      }
      if (!_current(generation)) throw StateError('录音已取消');
      final attachment = await attachments.addAudio(
        bytes.takeBytes(),
        noteId: noteId,
        name: '会议录音.m4a',
        canCommit: () => _current(generation),
      );
      await _cleanup();
      return attachment;
    } finally {
      if (_current(generation)) busy = false;
    }
  }

  Future<void> cancel() {
    if (_canceling != null) return _canceling!;
    _canceling = _cancel();
    return _canceling!.whenComplete(() => _canceling = null);
  }

  Future<void> _cancel() async {
    _generation++;
    busy = true;
    recording = false;
    try {
      await _recorder.cancel();
    } finally {
      try {
        await _cleanup();
      } finally {
        busy = false;
      }
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    try {
      await cancel();
    } finally {
      await _recorder.dispose();
    }
  }

  Future<void> _cleanup() async {
    final working = _working;
    _working = null;
    _path = null;
    if (working != null && await working.exists()) {
      await working.delete(recursive: true);
    }
  }
}
