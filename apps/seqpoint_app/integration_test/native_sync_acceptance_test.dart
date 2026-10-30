import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/seq_app.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'native_sync_support.dart';
import 'native_sync_pairing.dart';
import 'native_sync_media.dart';
import 'native_sync_background.dart';

void main() {
  final binding=IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('isolated native phone and desktop relay acceptance',(tester) async {
    const role=String.fromEnvironment('SYNC_ROLE');
    expect(role,anyOf('desktop','phone'));expect(Platform.isIOS,role=='phone');
    final root=await Directory.systemTemp.createTemp('seqpoint-native-$role-');
    final paths=PathProviderPlatform.instance,control=AcceptanceControl(role);
    final secrets=AcceptanceSecrets('acceptance.${root.path.split('/').last}');
    PathProviderPlatform.instance=AcceptancePaths(root);SharedPreferences.setMockInitialValues({});
    final http=HttpOverrides.current;
    HttpOverrides.global=AcceptanceHttp(Uri.parse(const String.fromEnvironment('SYNC_RELAY')),
      utf8.decode(base64Decode(const String.fromEnvironment('SYNC_CA'))));
    binding.addObserver(control);AppSyncService? service;
    addTearDown(() async {
      binding.removeObserver(control);await service?.stop();await secrets.clear();
      await tester.pumpWidget(const SizedBox.shrink());await tester.pumpAndSettle();
      PathProviderPlatform.instance=paths;control.close();HttpOverrides.global=http;
      await root.delete(recursive:true);
    });
    await tester.pumpWidget(SeqApp(syncFactory:(db,dir,changed)=>service=AppSyncService(
      db:db,root:dir,secrets:secrets,onCommittedChange:changed)));
    await until(()=>service!=null);await tester.pumpAndSettle();
    final sync=service!,scope=tester.widget<AppScope>(find.byType(AppScope));
    void reportStatus()=>unawaited(control.exchange('$role-state',{
      'status':sync.status,'error':sync.error,'message':sync.relayMessage,
      'canSync':sync.canSync,'auto':sync.automaticEnabled,'autocommit':scope.database!.raw.autocommit,
      'lifecycle':binding.lifecycleState?.name}).catchError((Object _)=>null));
    sync.addListener(reportStatus);addTearDown(()=>sync.removeListener(reportStatus));
    await pairNative(sync,control);reportStatus();
    final own=scope.noteService.capture('native-sync-$role');
    await control.exchange('$role-note',own.id);
    final peer=await control.wait(role=='desktop'?'phone-note':'desktop-note') as String;
    await until(()=>scope.notes.byId(peer)!=null,seconds:150);await control.exchange('$role-text-ready',true);
    await exchangeLargeMedia(scope.database!,root,own.id,control);
    await nativeBackground(scope,sync,role=='desktop'?own.id:peer,control);
    await control.exchange('$role-complete',true);
  },timeout:const Timeout(Duration(minutes:20)));
}
