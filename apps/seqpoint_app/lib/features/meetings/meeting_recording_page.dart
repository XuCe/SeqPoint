import 'dart:async';

import 'package:flutter/material.dart';

import 'recording_session.dart';

class MeetingRecordingPage extends StatefulWidget {
  const MeetingRecordingPage({super.key, required this.session});
  final RecordingSession session;
  @override
  State<MeetingRecordingPage> createState() => _MeetingRecordingPageState();
}

class _MeetingRecordingPageState extends State<MeetingRecordingPage>
    with WidgetsBindingObserver {
  Timer? _timer;
  int _seconds = 0;
  int _operation = 0;
  bool _busy = false;
  bool _disposed = false;
  bool _cancelBusy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.session.dispose().catchError((Object _) {}));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_cancel());
    }
  }

  bool _current(int operation) =>
      mounted && !_disposed && operation == _operation;
  Future<void> _run(
    Future<void> Function() action, {
    bool close = false,
  }) async {
    if (_busy) return;
    final operation = ++_operation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!_current(operation)) return;
      if (close) {
        Navigator.of(context).pop(true);
        return;
      }
      if (widget.session.recording) {
        _seconds = 0;
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted || _disposed) return;
          setState(() => _seconds++);
          if (_seconds >= 1800) {
            _timer?.cancel();
            unawaited(
              _run(() async {
                await widget.session.save();
              }, close: true),
            );
          }
        });
      }
    } catch (_) {
      if (_current(operation)) {
        setState(() => _error = '录音操作失败，请检查麦克风权限和本机空间；可重试保存或取消');
      }
    } finally {
      if (_current(operation)) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    if (_cancelBusy) return;
    _cancelBusy = true;
    final operation = ++_operation;
    _timer?.cancel();
    if (mounted && !_disposed) setState(() => _busy = true);
    try {
      await widget.session.cancel();
      if (_current(operation)) {
        setState(() {
          _seconds = 0;
          _error = '未保存的录音已取消';
        });
      }
    } catch (_) {
      if (_current(operation)) setState(() => _error = '取消录音失败，请重试');
    } finally {
      _cancelBusy = false;
      if (_current(operation)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('会议录音')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '请先确认与会者知晓录音。仅在前台录音；返回或切到后台会取消未保存内容。'
            '最长 30 分钟后自动停止并保存，最大 50 MB。录音仅保存在本机，不自动上传或转写。',
          ),
          const SizedBox(height: 24),
          Semantics(
            liveRegion: true,
            child: Text(
              '${(_seconds ~/ 60).toString().padLeft(2, '0')}:${(_seconds % 60).toString().padLeft(2, '0')}',
              style: Theme.of(context).textTheme.displaySmall,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (!widget.session.hasDraft)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _run(widget.session.start),
                  icon: const Icon(Icons.mic_none),
                  label: const Text('开始录音'),
                ),
              if (widget.session.hasDraft)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          _timer?.cancel();
                          await widget.session.save();
                        }, close: true),
                  icon: const Icon(Icons.stop),
                  label: Text(widget.session.recording ? '停止并保存' : '重试保存'),
                ),
              if (widget.session.hasDraft || _busy)
                TextButton(onPressed: _cancel, child: const Text('取消录音')),
            ],
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}
