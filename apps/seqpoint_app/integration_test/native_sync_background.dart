import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'native_sync_support.dart';

Future<void> nativeBackground(AppScope scope,AppSyncService sync,String desktopNote,
    AcceptanceControl control) async {
  const changed='native-sync-edited-while-phone-background';
  await control.wait('desktop-files-ready');await control.wait('phone-files-ready');
  await until(()=>!sync.busy);
  if(control.role=='desktop') {
    await control.wait('phone-background',seconds:900);
    final before=await control.exchange('status') as Map;
    final requests=((before['metrics'] as Map)['phone'] as Map)['requests'];
    scope.noteService.editContent(desktopNote,changed);
    await Future<void>.delayed(const Duration(seconds:70));
    await until(()=>!sync.busy);
    expect(sync.error,isNull);
    final after=await control.exchange('status') as Map;
    expect(((after['metrics'] as Map)['phone'] as Map)['requests'],requests);
    await control.exchange('background-no-network',true);
    await control.exchange('desktop-background-edit-ready',true);
    await control.wait('phone-resumed-and-synced',seconds:900);
  } else {
    await control.exchange('phone-ready-background',true);
    await control.wait('phone-background',seconds:900);
    await control.wait('desktop-background-edit-ready',seconds:900);
    await until(()=>WidgetsBinding.instance.lifecycleState==AppLifecycleState.resumed,seconds:900);
    await until(()=>scope.notes.byId(desktopNote)?.rawContent==changed,seconds:90);
    await control.exchange('phone-resumed-and-synced',true);
  }
}
