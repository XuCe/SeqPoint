import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 系统短句识别。确认后返回文字，由调用方沿用原有保存流程。
class VoiceInputPage extends StatefulWidget {
  const VoiceInputPage({super.key, this.speech});
  final SpeechToText? speech;
  @override
  State<VoiceInputPage> createState() => _VoiceInputPageState();
}

class _VoiceInputPageState extends State<VoiceInputPage>
    with WidgetsBindingObserver {
  static Object? _owner;
  final _text = TextEditingController();
  late final SpeechToText _speech = widget.speech ?? SpeechToText();
  bool _busy = false;
  bool _listening = false;
  String? _error;
  int _generation = 0;
  bool _disposed = false;
  bool _stopping = false;
  Completer<void>? _completion;
  Future<bool>? _initialization;
  Future<void>? _canceling;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_cancel());
    _text.dispose();
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

  bool _current(int generation) =>
      mounted && !_disposed && generation == _generation;
  Future<void> _start() async {
    if (_busy || _listening) return;
    if (_owner != null && !identical(_owner, this)) {
      setState(() => _error = '已有语音输入正在使用麦克风');
      return;
    }
    _owner = this;
    final generation = ++_generation;
    _completion = Completer<void>();
    final prefix = _text.text.isEmpty ? '' : '${_text.text}\n';
    setState(() {
      _busy = true;
      _error = null;
    });
    void failed() {
      if (!_current(generation)) return;
      setState(() => _error = '语音识别不可用，请检查系统权限或改用文字输入');
      unawaited(_cancel());
    }

    void status(String value) {
      if (!_current(generation) || value != SpeechToText.doneStatus) return;
      if (!_completion!.isCompleted) _completion!.complete();
      if (_stopping) return;
      setState(() {
        _listening = false;
        _busy = false;
      });
      if (identical(_owner, this)) _owner = null;
    }

    _speech.statusListener = status;
    _speech.errorListener = (_) => failed();
    try {
      _initialization ??= _speech.initialize(
        onStatus: status,
        onError: (_) => failed(),
        options: [SpeechToText.androidNoBluetooth],
      );
      final available = await _initialization!;
      if (!_current(generation)) return;
      if (!available) {
        _initialization = null;
        failed();
        return;
      }
      setState(() {
        _busy = false;
        _listening = true;
      });
      _speech.statusListener = status;
      _speech.errorListener = (_) => failed();
      await _speech.listen(
        onResult: (result) {
          if (!_current(generation) || !_listening) return;
          _text.text = '$prefix${result.recognizedWords}';
          if (_stopping && result.finalResult && !_completion!.isCompleted) {
            _completion!.complete();
          }
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          cancelOnError: true,
          partialResults: true,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 5),
        ),
      );
    } catch (_) {
      _initialization = null;
      failed();
    }
  }

  Future<void> _stop() async {
    if (_busy || !_listening) return;
    final generation = _generation;
    _stopping = true;
    setState(() => _busy = true);
    try {
      await _speech.stop();
      await _completion!.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      if (_current(generation)) {
        setState(() => _error = '识别收尾失败，已识别文字保留，请检查后确认');
        await _cancel();
      }
    } finally {
      if (_current(generation)) {
        _generation++;
        setState(() {
          _busy = false;
          _listening = false;
        });
        if (identical(_owner, this)) _owner = null;
      }
      _stopping = false;
    }
  }

  Future<void> _cancel() {
    if (_canceling != null) return _canceling!;
    _canceling = _cancelSession();
    return _canceling!.whenComplete(() => _canceling = null);
  }

  Future<void> _cancelSession() async {
    _generation++;
    if (_completion != null && !_completion!.isCompleted) {
      _completion!.complete();
    }
    if (mounted && !_disposed) {
      setState(() {
        _busy = true;
        _listening = false;
      });
    }
    try {
      if (identical(_owner, this)) {
        await _initialization;
        await _speech.cancel();
      }
    } catch (_) {
      if (mounted && !_disposed) setState(() => _error = '取消识别失败，请检查麦克风状态');
    } finally {
      _stopping = false;
      if (mounted && !_disposed) setState(() => _busy = false);
      if (identical(_owner, this)) _owner = null;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('语音输入'),
      actions: [
        TextButton(
          onPressed: _busy || _listening
              ? null
              : () {
                  final text = _text.text.trim();
                  if (text.isNotEmpty) Navigator.of(context).pop(text);
                },
          child: const Text('确认文字'),
        ),
      ],
    ),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '点击开始后使用系统语音识别。系统服务可能联网处理语音；'
            '识别适合短句，最长 60 秒，设备可能提前停止。确认前可修改文字。',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : (_listening ? _stop : _start),
                icon: Icon(_listening ? Icons.stop : Icons.mic_none),
                label: Text(_listening ? '停止识别' : '开始语音输入'),
              ),
              if (_listening || _busy)
                TextButton(onPressed: _cancel, child: const Text('取消识别')),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: _text,
              readOnly: _listening || _busy,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                labelText: '识别文字',
                hintText: '识别结果会出现在这里，也可以直接输入文字',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
