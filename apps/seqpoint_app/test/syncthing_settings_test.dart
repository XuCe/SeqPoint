import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/settings/syncthing_settings.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {}

class _Service extends AppSyncService {
  _Service(SeqDatabase db)
    : super(db: db, root: Directory('/unused'), secrets: _Secrets());
  String? savedAddress, savedKey;
  bool fail = false;
  @override
  bool get canSync => true;
  @override
  bool get syncthingSupported => true;
  @override
  Future<String> loadSyncthingAddress() async => 'http://192.168.1.10:8384';
  @override
  Future<void> saveSyncthing({
    required String address,
    required String apiKey,
  }) async {
    if (fail) throw StateError('unavailable');
    savedAddress = address;
    savedKey = apiKey;
  }
}

void main() {
  testWidgets('Syncthing form and setup guide work on narrow screens without exposing keys', (
    tester,
  ) async {
    final db = SeqDatabase.inMemory()..migrate();
    final service = _Service(db);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SyncthingSettings(service: service, disabled: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('连接 Syncthing 节点'), findsOneWidget);
    expect(find.textContaining('NAS'), findsNothing);
    expect(find.text('Syncthing 管理 API 地址'), findsOneWidget);
    final key = find.byKey(const ValueKey('syncthing-api-key'));
    expect(tester.widget<TextField>(key).obscureText, isTrue);
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    await tester.enterText(key, 'new-key');
    await tester.ensureVisible(find.text('保存并授权'));
    await tester.tap(find.text('保存并授权'));
    await tester.pumpAndSettle();
    expect(service.savedAddress, 'http://192.168.1.10:8384');
    expect(service.savedKey, 'new-key');
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    final guide = find.text('如何搭建 Syncthing · 端口怎么开放');
    await tester.ensureVisible(guide);
    await tester.tap(guide);
    await tester.pumpAndSettle();
    expect(find.text('最小端口开放范围'), findsOneWidget);
    expect(find.textContaining('22000/TCP'), findsOneWidget);
    expect(find.textContaining('不要把管理端口映射到公网'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await service.stop();
    service.dispose();
    db.close();
  });
}
