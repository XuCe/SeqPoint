import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/features/meetings/meeting_audio_page.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

class _Player extends Fake implements AudioPlayer {
  final states = StreamController<PlayerState>.broadcast();
  final calls = <String>[];
  Completer<void>? stopping;
  Object? stopError;
  Object? playError;
  @override
  Source? source;
  @override
  Stream<PlayerState> get onPlayerStateChanged => states.stream;
  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    calls.add('play');
    if (playError != null) throw playError!;
    this.source = source;
    states.add(PlayerState.playing);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    states.add(PlayerState.paused);
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
    states.add(PlayerState.playing);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    await stopping?.future;
    if (stopError != null) throw stopError!;
    states.add(PlayerState.stopped);
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }
}

class _AudioFile extends Fake implements File {
  final bytes = Uint8List.fromList([1, 2, 3]);
  int? reportedLength;
  List<List<int>>? chunks;
  int opened = 0;
  String filePath = '/fake-managed/recording';
  @override
  String get path => filePath;
  @override
  Future<int> length() async => reportedLength ?? bytes.length;
  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    opened++;
    return Stream.fromIterable(chunks ?? [bytes]);
  }
}

class _Attachments extends Fake implements AttachmentService {
  final audio = _AudioFile();
  Object? error;
  Completer<File>? pending;
  int reads = 0;
  @override
  Future<File> file(String id) async {
    reads++;
    if (error != null) throw error!;
    return pending == null ? audio : pending!.future;
  }
}

final _recording = Attachment(
  id: '6d461287-379d-4ab7-bf9a-3c1e85b00610',
  noteId: 'note',
  mime: 'audio/mp4',
  byteSize: 3,
  sha256: '',
  createdAt: DateTime(2026),
  media: 'audio',
  fileName: '会议.m4a',
);

void main() {
  for (final changeService in [false, true]) {
    testWidgets('停止失败后切换播放身份不得继续旧录音：service=$changeService', (tester) async {
      final player = _Player();
      final files = _Attachments();
      Widget page(Attachment recording, AttachmentService service) =>
          MaterialApp(
            home: MeetingAudioPage(
              attachments: service,
              recording: recording,
              player: player,
            ),
          );
      await tester.pumpWidget(page(_recording, files));
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      final nextFiles = changeService ? _Attachments() : files;
      nextFiles.audio.filePath = '/fake-managed/next';
      final nextRecording = changeService
          ? _recording
          : Attachment(
              id: 'next',
              noteId: 'note',
              mime: 'audio/mp4',
              byteSize: 3,
              sha256: '',
              createdAt: DateTime(2026),
              media: 'audio',
              fileName: '另一场会议.m4a',
            );
      player.stopError = StateError('native stop failed');
      await tester.pumpWidget(page(nextRecording, nextFiles));
      await tester.pumpAndSettle();
      expect(find.text('停止播放失败，请关闭此页面重试'), findsOneWidget);
      expect(player.calls, ['play', 'pause', 'stop']);
      player.playError = StateError('new source failed');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(player.calls.where((call) => call == 'resume'), isEmpty);
      expect(
        (player.source! as DeviceFileSource).path,
        '/fake-managed/recording',
      );
      expect(find.text('无法播放本机录音，请确认文件仍在此设备'), findsOneWidget);
      player.playError = null;
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(player.calls.where((call) => call == 'resume'), isEmpty);
      expect((player.source! as DeviceFileSource).path, '/fake-managed/next');
      expect(nextFiles.reads, changeService ? 2 : 3);
    });
  }

  testWidgets('导出读取中切到后台，停止未完成前不重入或迟到打开保存', (tester) async {
    final player = _Player()..stopping = Completer<void>();
    final files = _Attachments()..pending = Completer<File>();
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MeetingAudioPage(
          attachments: files,
          recording: _recording,
          player: player,
          save: ({required fileName, required bytes}) async {
            saves++;
            return '/chosen';
          },
        ),
      ),
    );
    await tester.tap(find.text('导出录音'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    files.pending!.complete(files.audio);
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '导出录音'))
          .onPressed,
      isNull,
    );
    expect(saves, 0);
    expect(player.calls, ['stop']);
    expect(files.audio.opened, 0);
    player.stopping!.complete();
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(player.calls, ['stop']);
  });

  testWidgets('原生停止尚未完成时禁止播放和导出重入', (tester) async {
    final player = _Player()..stopping = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: MeetingAudioPage(
          attachments: _Attachments(),
          recording: _recording,
          player: player,
        ),
      ),
    );
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '导出录音'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '停止'))
          .onPressed,
      isNull,
    );
    expect(player.calls, ['play', 'stop']);
    player.stopping!.complete();
    await tester.pumpAndSettle();
    expect(find.text('播放'), findsOneWidget);
  });

  testWidgets('切换录音释放原播放，不会自动播放新录音', (tester) async {
    final player = _Player();
    final files = _Attachments();
    Widget page(Attachment recording) => MaterialApp(
      home: MeetingAudioPage(
        attachments: files,
        recording: recording,
        player: player,
      ),
    );
    await tester.pumpWidget(page(_recording));
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      page(
        Attachment(
          id: 'fd22e260-eaa3-4d9d-8bdf-d91c0af41c80',
          noteId: 'note',
          mime: 'audio/mp4',
          byteSize: 3,
          sha256: '',
          createdAt: DateTime(2026),
          media: 'audio',
          fileName: '另一场会议.m4a',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(player.calls, ['play', 'stop']);
    expect(files.reads, 1);
    expect(find.text('另一场会议.m4a'), findsOneWidget);
  });

  testWidgets('停止会取消尚未完成的播放请求', (tester) async {
    final player = _Player();
    final files = _Attachments()..pending = Completer<File>();
    await tester.pumpWidget(
      MaterialApp(
        home: MeetingAudioPage(
          attachments: files,
          recording: _recording,
          player: player,
        ),
      ),
    );
    await tester.tap(find.text('播放'));
    await tester.pump();
    await tester.tap(find.text('停止'));
    await tester.pump();
    files.pending!.complete(files.audio);
    await tester.pumpAndSettle();
    expect(player.calls, ['stop']);
    expect(find.text('播放'), findsOneWidget);
  });

  testWidgets('文件大小变化时拒绝播放和导出', (tester) async {
    final player = _Player();
    final files = _Attachments();
    var saved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MeetingAudioPage(
          attachments: files,
          recording: _recording,
          player: player,
          save: ({required fileName, required bytes}) async {
            saved = true;
            return '/chosen';
          },
        ),
      ),
    );
    files.audio.reportedLength = 4;
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(player.calls, isEmpty);
    files.audio.reportedLength = null;
    files.audio.chunks = [
      [1, 2, 3],
      [4],
    ];
    await tester.tap(find.text('导出录音'));
    await tester.pumpAndSettle();
    expect(saved, isFalse);
    expect(find.text('录音导出失败，原文件已保留'), findsOneWidget);
  });

  testWidgets('默认导出准确交给系统保存接口，取消时不写文件', (tester) async {
    const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final player = _Player();
    await tester.pumpWidget(
      MaterialApp(
        home: MeetingAudioPage(
          attachments: _Attachments(),
          recording: _recording,
          player: player,
        ),
      ),
    );
    await tester.tap(find.text('导出录音'));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'save');
    final arguments = calls.single.arguments as Map;
    expect(arguments['bytes'], [1, 2, 3]);
    expect(arguments['allowedExtensions'], ['m4a']);
    expect(find.text('已取消导出'), findsOneWidget);
    expect(player.calls, isEmpty);
  });

  testWidgets('只有点击后播放，暂停继续停止，并在离页释放', (tester) async {
    final player = _Player();
    final files = _Attachments();
    await tester.pumpWidget(
      MaterialApp(
        home: MeetingAudioPage(
          attachments: files,
          recording: _recording,
          player: player,
        ),
      ),
    );
    expect(player.calls, isEmpty);
    expect(files.reads, 0);
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(player.calls, ['play']);
    expect((player.source! as DeviceFileSource).path, files.audio.path);
    expect(player.source!.mimeType, 'audio/mp4');
    await tester.tap(find.text('暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续播放'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(player.calls, ['play', 'pause', 'resume', 'stop']);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(player.calls.last, 'dispose');
  });

  testWidgets('导出由系统明确选择位置，取消后可以重试', (tester) async {
    final player = _Player();
    final files = _Attachments();
    final exports = <Uint8List>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MeetingAudioPage(
          attachments: files,
          recording: _recording,
          player: player,
          save: ({required fileName, required bytes}) async {
            expect(fileName, matches(r'^seqpoint-recording-[a-f0-9-]+\.m4a$'));
            exports.add(bytes);
            return exports.length == 1 ? null : '/chosen/会议.m4a';
          },
        ),
      ),
    );
    expect(exports, isEmpty);
    await tester.tap(find.text('导出录音'));
    await tester.pumpAndSettle();
    expect(exports.single, [1, 2, 3]);
    expect(find.text('已取消导出'), findsOneWidget);
    expect(player.calls, isEmpty);
    await tester.tap(find.text('导出录音'));
    await tester.pumpAndSettle();
    expect(exports.length, 2);
    expect(find.text('录音已交由系统保存'), findsOneWidget);
    expect(files.audio.bytes, [1, 2, 3]);
  });

  testWidgets('后台停止，返回前台不会自动播放', (tester) async {
    final player = _Player();
    await tester.pumpWidget(
      MaterialApp(
        home: MeetingAudioPage(
          attachments: _Attachments(),
          recording: _recording,
          player: player,
        ),
      ),
    );
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(player.calls, ['play', 'stop']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(player.calls, ['play', 'stop']);
  });

  testWidgets('读取尚未完成就离页，不会迟到开始播放', (tester) async {
    final player = _Player();
    final files = _Attachments()..pending = Completer<File>();
    await tester.pumpWidget(
      MaterialApp(
        home: MeetingAudioPage(
          attachments: files,
          recording: _recording,
          player: player,
        ),
      ),
    );
    await tester.tap(find.text('播放'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    files.pending!.complete(files.audio);
    await tester.pumpAndSettle();
    expect(player.calls, ['dispose']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('丢失录音或保存失败会显示错误并保留原件', (tester) async {
    final player = _Player();
    final files = _Attachments()..error = const FileSystemException('missing');
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MeetingAudioPage(
          attachments: files,
          recording: _recording,
          player: player,
          save: ({required fileName, required bytes}) async {
            saves++;
            throw const FileSystemException('save failed');
          },
        ),
      ),
    );
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(find.text('无法播放本机录音，请确认文件仍在此设备'), findsOneWidget);
    expect(player.calls, isEmpty);
    files.error = null;
    await tester.tap(find.text('导出录音'));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(find.text('录音导出失败，原文件已保留'), findsOneWidget);
    expect(files.audio.bytes, [1, 2, 3]);
  });
}
