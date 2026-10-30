import 'dart:convert';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'native_sync_support.dart';

Future<void> pairNative(AppSyncService service,AcceptanceControl control) async {
  final desktop=control.role=='desktop';
  await service.prepare(control.role);
  late PairingHandshake session;
  if(desktop) {
    await service.newVault();
    await control.exchange('invitation',(await service.createInvitation()).toQrPayload());
    session=await service.acceptResponse(Map<String,Object?>.from(await control.wait('response') as Map));
  } else {
    session=await service.respondToInvitation(Map<String,Object?>.from(await control.wait('invitation') as Map));
    await control.exchange('response',session.response.toJson());
  }
  await control.exchange('${control.role}-short',session.shortCode);
  final peer=desktop?'phone':'desktop';
  if(await control.wait('$peer-short')!=session.shortCode) throw StateError('Native pairing SAS mismatch');
  await control.exchange('${control.role}-confirm',await session.confirmShortCode(session.shortCode));
  await session.acceptConfirmation(Map<String,Object?>.from(await control.wait('$peer-confirm') as Map));
  if(desktop) {
    await control.exchange('packet',await service.finishHost(session));
    await control.wait('paired');
    await control.exchange('config',jsonDecode(service.relayNodeConfiguration));
  } else {
    await service.finishGuest(session,Map<String,Object?>.from(await control.wait('packet') as Map));
    await control.exchange('paired',true);await control.wait('config');
  }
  await service.saveRelayEndpoint(const String.fromEnvironment('SYNC_RELAY'));
  await service.setMediaSyncEnabled(true);
}
