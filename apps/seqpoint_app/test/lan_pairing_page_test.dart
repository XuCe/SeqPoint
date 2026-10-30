import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_app/sync/lan_pairing_page.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {}

void main() {
  testWidgets(
    'narrow pairing page validates the address before preparing identity',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = SeqDatabase.inMemory()..migrate();
      final service = AppSyncService(
        db: db,
        root: Directory('/unused'),
        secrets: _Secrets(),
      );
      addTearDown(() {
        service.dispose();
        db.close();
      });
      await tester.pumpWidget(
        MaterialApp(home: LanPairingPage(service: service)),
      );
      expect(find.text('等待设备连接'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('lan-address')),
        'https://example.com',
      );
      await tester.tap(find.text('连接此地址'));
      await tester.pumpAndSettle();
      expect(find.text('请输入有效的 IP:端口'), findsOneWidget);
      expect(service.prepared, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await service.stop();
    },
  );
}
