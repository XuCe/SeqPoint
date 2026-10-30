import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  int writes=0;
  @override Future<void> write(String key,String value) async {writes++;}
}
class _Automatic extends AppSyncService {
  _Automatic({required super.db,required super.root,required super.secrets});
  int rounds=0;
  @override bool get canSync=>true;
  @override bool get prepared=>true;
  @override String get relayVaultId=>'v'*43;
  @override Future<String> loadRelayEndpoint() async=>'https://example.test';
  @override Future<SyncOutcome> syncRelay({bool automatic=false}) async {
    expect(automatic,isTrue);rounds++;
    return const SyncOutcome(pulled:0,pushed:0,reclaimed:0,peers:[]);
  }
}
void main() {
  setUp(()=>SharedPreferences.setMockInitialValues({}));
  testWidgets('startup does not create an identity for an unbound local database',(tester) async {
    final db=SeqDatabase.inMemory()..migrate(),secrets=_Secrets();
    final service=AppSyncService(db:db,root:Directory('/unused'),secrets:secrets);
    await service.startAutomatic();await tester.pump(const Duration(seconds:3));
    expect(secrets.writes,0);expect(service.prepared,isFalse);
    await service.stop();service.dispose();db.close();
  });
  test('automatic startup honors user pause and stop cancels timers',() async {
    final db=SeqDatabase.inMemory()..migrate();SyncBaseline(db).initialize('a'*43);
    final service=_Automatic(db:db,root:Directory('/unused'),secrets:_Secrets());
    await service.startAutomatic();expect(service.error,isNull);
    await Future<void>.delayed(const Duration(milliseconds:1200));
    expect(service.rounds,1);await service.pause();
    await service.resumeAutomatic();await Future<void>.delayed(const Duration(milliseconds:1100));
    expect(service.rounds,1);expect((await SharedPreferences.getInstance()).getBool('sync.user.paused'),isTrue);
    await service.stop();await Future<void>.delayed(const Duration(milliseconds:1100));expect(service.rounds,1);
    service.dispose();db.close();
  });
}
