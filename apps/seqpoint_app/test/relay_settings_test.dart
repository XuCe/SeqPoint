import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/settings/relay_settings.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {}

class _Relay extends AppSyncService {
  _Relay(superDb)
    : super(db: superDb, root: Directory('unused'), secrets: _Secrets());
  String address = 'https://old.example.com';
  int syncs = 0;
  Completer<void>? gate;
  @override
  bool get canSync => true;
  @override
  Future<String> loadRelayEndpoint() async => address;
  @override
  Future<void> saveRelayEndpoint(String endpoint) async {
    address = endpoint;
  }

  @override
  String get relayNodeConfiguration => '{"public":"only"}';
  @override
  Future<SyncOutcome> syncRelay({bool automatic=false}) async {
    syncs++;
    await gate?.future;
    return const SyncOutcome(pulled: 0, pushed: 0, reclaimed: 0, peers: []);
  }
}

void main() {
  testWidgets(
    'loads address, saves edited address before sync and prevents double submit',
    (tester) async {
      final db = SeqDatabase.inMemory()..migrate();
      final service = _Relay(db);
      addTearDown(() {
        service.dispose();
        db.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RelaySettings(service: service, disabled: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('https://old.example.com'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'https://new.example.com');
      service.gate = Completer<void>();
      await tester.tap(find.text('云同步一次'));
      await tester.pump();
      expect(service.address, 'https://new.example.com');
      expect(service.syncs, 1);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      service.gate!.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'copies only exported public configuration and disables controls during restore',
    (tester) async {
      final db = SeqDatabase.inMemory()..migrate();
      final service = _Relay(db);
      addTearDown(() {
        service.dispose();
        db.close();
      });
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Widget page(bool disabled) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RelaySettings(service: service, disabled: disabled),
          ),
        ),
      );
      await tester.pumpWidget(page(false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制节点配置'));
      await tester.pumpAndSettle();
      expect(copied, service.relayNodeConfiguration);
      expect(find.textContaining('节点配置已复制'), findsOneWidget);
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    },
  );
}
