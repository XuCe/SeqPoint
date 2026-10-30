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
  Future<String> loadSyncthingAddress() async => 'nas.example.com:8384';
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
  testWidgets('NAS form works on narrow screens and never shows saved keys', (
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
    final key = find.byKey(const ValueKey('syncthing-api-key'));
    expect(tester.widget<TextField>(key).obscureText, isTrue);
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    await tester.enterText(key, 'new-key');
    await tester.ensureVisible(find.text('保存并授权'));
    await tester.tap(find.text('保存并授权'));
    await tester.pumpAndSettle();
    expect(service.savedAddress, 'nas.example.com:8384');
    expect(service.savedKey, 'new-key');
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await service.stop();
    service.dispose();
    db.close();
  });
}
