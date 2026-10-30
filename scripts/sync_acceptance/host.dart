import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'gateway.dart';

Future<({Process process,int port})> startNode(Directory root,Object config,String binary) async {
  await File('${root.path}/node.json').writeAsString(jsonEncode(config));
  final process=await Process.start(binary,['-config','${root.path}/node.json',
    '-data','${root.path}/data','-listen','127.0.0.1:0']);
  final ready=Completer<int>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if(line.startsWith('listening=') && !ready.isCompleted) ready.complete(int.parse(line.split(':').last));
  },onDone:(){if(!ready.isCompleted) ready.completeError(StateError('Node exited'));});
  unawaited(process.stderr.drain<void>());
  try {
    return (process:process,port:await ready.future.timeout(const Duration(seconds:15)));
  } catch (_) {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode;
    rethrow;
  }
}

Future<void> main(List<String> args) async {
  final root=await Directory.systemTemp.createTemp('seqpoint-native-sync-');
  final fixtures='${Directory.current.path}/packages/seqpoint_core/test/sync/transport/fixtures';
  final certificate=await File('$fixtures/localhost_cert.pem').readAsBytes();
  final tls=SecurityContext()..useCertificateChainBytes(certificate)
    ..usePrivateKey('$fixtures/localhost_key.pem');
  final nodePort=Completer<int>(),values=<String,Object?>{},report=<String,Object>{};
  Process? node;
  Future<({Process process,int port})>? starting;
  final gateways=[for(final role in ['desktop','phone']) await startGateway(tls,nodePort.future,role,report)];
  final control=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
  final setup={'control':'http://127.0.0.1:${control.port}',
    'desktop':'https://127.0.0.1:${gateways[0].port}','phone':'https://127.0.0.1:${gateways[1].port}',
    'ca':base64Encode(certificate),'run':root.path.split('/').last};
  await File('${root.path}/setup.json').writeAsString(jsonEncode(setup));
  stdout.writeln('SETUP=${root.path}/setup.json');
  control.listen((request) async {
    try {
      final key=request.uri.pathSegments.last;
      if(request.uri.path.startsWith('/fixture/') && const ['large.png','large.m4a'].contains(key)) {
        await request.response.addStream(File('${root.path}/$key').openRead());
        await request.response.close();return;
      }
      if(request.method=='POST') {
        final body=await utf8.decoder.bind(request).join();
        values[key]=jsonDecode(body);report['lastEvent']=key;
        if(key=='config' && node==null) {
          starting=startNode(root,values[key]!,args.single);
          final started=await starting!;
          node=started.process;nodePort.complete(started.port);
        }
        if(key=='phone-lifecycle' && values['phone-ready-background']==true &&
            const ['paused','hidden'].contains(values[key])) {values['phone-background']=true;}
      }
      request.response.headers.contentType=ContentType.json;
      request.response.write(jsonEncode(key=='status'?{'metrics':report,'events':values.keys.toList(),
        'background':values['phone-background'],'lifecycle':values['phone-lifecycle']}:values[key]));
      await request.response.close();
      await File('${root.path}/report.json').writeAsString(jsonEncode(report));
    } catch(error) {
      request.response.statusCode=500;request.response.write('$error');await request.response.close();
    }
  });
  final stopped=Completer<void>();
  final signals=[for(final signal in [ProcessSignal.sigterm,ProcessSignal.sigint])
    signal.watch().listen((_){if(!stopped.isCompleted) stopped.complete();})];
  await stopped.future;
  for(final subscription in signals) {await subscription.cancel();}
  try {
    node ??= (await starting)?.process;
  } catch (_) {
    // startNode already reaped the failed process; the request reports its error.
  }
  await control.close(force:true);
  for(final gateway in gateways) {await gateway.close(force:true);}
  node?.kill(ProcessSignal.sigterm);await node?.exitCode;
  stdout.writeln('REPORT=${root.path}/report.json');
}
