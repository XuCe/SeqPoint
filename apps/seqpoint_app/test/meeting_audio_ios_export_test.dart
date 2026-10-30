import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:seqpoint_app/features/meetings/meeting_audio_page.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

class _Paths extends PathProviderPlatform {
  Completer<String?>? pending;
  int requests = 0;
  @override
  Future<String?> getApplicationDocumentsPath() async {
    requests++;
    return pending == null ? '/fake-documents' : pending!.future;
  }
}

class _Player extends Fake implements AudioPlayer {
  @override
  Stream<PlayerState> get onPlayerStateChanged => const Stream.empty();
  @override
  Future<void> dispose() async {}
  @override
  Future<void> stop() async {}
}

class _AudioFile extends Fake implements File {
  @override
  Future<int> length() async => 3;
  @override
  Stream<List<int>> openRead([int? start, int? end]) => Stream.value([1, 2, 3]);
}

class _Attachments extends Fake implements AttachmentService {
  @override
  Future<File> file(String id) async => _AudioFile();
}

class _Staging extends Fake implements File {
  _Staging(this.path);
  @override
  final String path;
  bool present = false;
  int deletions = 0;
  Completer<bool>? pending;
  @override
  Future<bool> exists() async => pending == null ? present : pending!.future;
  @override
  Future<File> delete({bool recursive = false}) async {
    deletions++;
    present = false;
    return this;
  }
}

void main() {
  for (final (action, boundary) in [
    ('switch', 'directory'),
    ('background', 'directory'),
    ('switch', 'exists'),
    ('background', 'exists'),
  ]) {
    testWidgets('iOS保存准备延迟后失效请求不打开保存：$action/$boundary', (tester) async {
      final previous = PathProviderPlatform.instance;
      final paths = _Paths();
      final heldExists = Completer<bool>();
      if (boundary == 'directory') paths.pending = Completer<String?>();
      PathProviderPlatform.instance = paths;
      addTearDown(() => PathProviderPlatform.instance = previous);
      final files = _Attachments();
      final player = _Player();
      var saves = 0;
      var preparedCopies = 0;
      const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        _,
      ) async {
        saves++;
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      Widget page(String id) => MaterialApp(
        home: MeetingAudioPage(
          attachments: files,
          player: player,
          recording: Attachment(
            id: id,
            noteId: 'note',
            mime: 'audio/mp4',
            byteSize: 3,
            sha256: '',
            createdAt: DateTime(2026),
            media: 'audio',
          ),
        ),
      );
      await tester.pumpWidget(page('first'));
      await IOOverrides.runZoned(
        () async {
          await tester.tap(find.text('导出录音'));
          await tester.pump();
          expect(paths.requests, 1);
          expect(preparedCopies, boundary == 'directory' ? 0 : 1);
          if (action == 'switch') {
            await tester.pumpWidget(page('second'));
          } else {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            await tester.pump();
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pump();
          }
          if (boundary == 'directory') {
            paths.pending!.complete('/fake-documents');
          } else {
            heldExists.complete(false);
          }
          await tester.pumpAndSettle();
        },
        createFile: (path) {
          preparedCopies++;
          return _Staging(path)
            ..pending = boundary == 'exists' ? heldExists : null;
        },
      );
      expect(saves, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  for (final target in ['cancel', 'same', 'alias', 'other']) {
    testWidgets('iOS精确清理本次暂存，保留用户目标：$target', (tester) async {
      final sameTarget = target == 'same' || target == 'alias';
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths();
      addTearDown(() {
        PathProviderPlatform.instance = previousPaths;
      });
      final staging = <String, _Staging>{};
      const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'save');
        final name = (call.arguments as Map)['fileName'] as String;
        final file = staging['/fake-documents/$name']!;
        file.present = true;
        return switch (target) {
          'cancel' => null,
          'same' => file.path,
          'alias' => '/fake-alias/recording.m4a',
          _ => '/chosen/meeting.m4a',
        };
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MeetingAudioPage(
            attachments: _Attachments(),
            player: _Player(),
            recording: Attachment(
              id: 'audio',
              noteId: 'note',
              mime: 'audio/mp4',
              byteSize: 3,
              sha256: '',
              createdAt: DateTime(2026),
              media: 'audio',
            ),
          ),
        ),
      );
      await IOOverrides.runZoned(
        () async {
          await tester.tap(find.text('导出录音'));
          await tester.pumpAndSettle();
        },
        fseIdentical: (managed, destination) async {
          expect(managed, staging.values.single.path);
          expect(
            destination,
            target == 'alias'
                ? '/fake-alias/recording.m4a'
                : '/chosen/meeting.m4a',
          );
          return target == 'alias';
        },
        createFile: (path) {
          expect(path, startsWith('/fake-documents/seqpoint-recording-'));
          expect(path, endsWith('.m4a'));
          return staging.putIfAbsent(path, () => _Staging(path));
        },
      );
      expect(staging.length, 1);
      expect(staging.values.single.deletions, sameTarget ? 0 : 1);
      expect(staging.values.single.present, sameTarget);
      expect(
        find.text(target == 'cancel' ? '已取消导出' : '录音已交由系统保存'),
        findsOneWidget,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }
}
