import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:seqpoint_app/platform/secure_secret_store.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class AcceptancePaths extends PathProviderPlatform {
  AcceptancePaths(this.directory);
  final Directory directory;
  @override Future<String?> getApplicationSupportPath() async=>directory.path;
}
class AcceptanceSecrets implements SecretStore {
  AcceptanceSecrets(this.prefix);
  final String prefix;
  final _keys=<String>{};
  final _store=const SecureSecretStore();
  @override Future<void> write(String key,String value) async {
    _keys.add(key);await _store.write('$prefix.$key',value);
  }
  @override Future<String?> read(String key)=>_store.read('$prefix.$key');
  @override Future<bool> containsKey(String key)=>_store.containsKey('$prefix.$key');
  @override Future<void> delete(String key)=>_store.delete('$prefix.$key');
  Future<void> clear() async {for(final key in _keys) {await delete(key);}}
}
class AcceptanceControl extends WidgetsBindingObserver {
  AcceptanceControl(this.role);
  final String role;
  final _http=HttpClient()..connectionTimeout=const Duration(seconds:5);
  Future<Object?> exchange(String key,[Object? value]) async {
    final request=await _http.openUrl(value==null?'GET':'POST',
      Uri.parse('${const String.fromEnvironment('SYNC_CONTROL')}/$key'));
    if(value!=null) request.add(utf8.encode(jsonEncode(value)));
    final response=await request.close();
    final body=await utf8.decoder.bind(response).join();
    if(response.statusCode!=200) throw StateError('Control $key: $body');
    return jsonDecode(body);
  }
  Future<Uint8List> fixture(String name) async {
    final response=await (await _http.getUrl(Uri.parse(
      '${const String.fromEnvironment('SYNC_CONTROL')}/fixture/$name'))).close();
    if(response.statusCode!=200) throw StateError('Fixture download failed');
    final bytes=BytesBuilder(copy:false);
    await for(final part in response) {bytes.add(part);}
    return bytes.takeBytes();
  }
  Future<Object> wait(String key,{int seconds=300}) async {
    final deadline=DateTime.now().add(Duration(seconds:seconds));
    while(DateTime.now().isBefore(deadline)) {
      final value=await exchange(key);if(value!=null) return value;
      await Future<void>.delayed(const Duration(milliseconds:300));
    }
    throw StateError('Timed out waiting for $key');
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(exchange('$role-lifecycle',state.name).catchError((Object _)=>null));
  }
  void close()=>_http.close(force:true);
}

Future<void> until(bool Function() ready,{int seconds=240}) async {
  final deadline=DateTime.now().add(Duration(seconds:seconds));
  while(!ready()) {
    if(DateTime.now().isAfter(deadline)) throw StateError('Native sync condition timed out');
    await Future<void>.delayed(const Duration(milliseconds:300));
  }
}

class AcceptanceHttp extends HttpOverrides {
  AcceptanceHttp(this.endpoint,this.certificate);
  final Uri endpoint;
  final String certificate;
  @override HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)..badCertificateCallback=(peer,host,port)=>
      host=='127.0.0.1' && port==endpoint.port && peer.pem.trim()==certificate.trim();
  }
}
