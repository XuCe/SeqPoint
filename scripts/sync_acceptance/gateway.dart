import 'dart:async';
import 'dart:io';

Future<HttpServer> startGateway(SecurityContext tls,Future<int> nodePort,
    String role,Map<String,Object> report) async {
  final server=await HttpServer.bindSecure(InternetAddress.loopbackIPv4,0,tls);
  final client=HttpClient()..connectionTimeout=const Duration(seconds:10);
  final completed=<String,int>{};
  report[role]={'requests':0,'bytes':0,'complete':completed,'faults':0};
  final stats=report[role] as Map;
  var blobGets=0,faultUsed=false;DateTime? offlineUntil;
  server.listen((request) async {
    final path=request.uri.queryParameters['path']??'';
    stats['requests']=(stats['requests'] as int)+1;
    stats['lastRequest']=DateTime.now().toUtc().toIso8601String();
    final blob=request.method=='GET' && path.startsWith('blobs/');
    try {
      if(offlineUntil!=null && DateTime.now().isBefore(offlineUntil!)) {
        request.response.statusCode=503;await request.response.close();return;
      }
      final upstream=await client.openUrl(request.method,request.uri.replace(
        scheme:'http',host:'127.0.0.1',port:await nodePort));
      request.headers.forEach((name,values) {
        if(name.toLowerCase()!='host') upstream.headers.set(name,values);
      });
      await upstream.addStream(request);
      final response=await upstream.close();request.response.statusCode=response.statusCode;
      final bytes=await response.fold<List<int>>([], (all,part)=>all..addAll(part));
      request.response.contentLength=bytes.length;
      if(role=='phone' && blob && bytes.length>900*1024 && ++blobGets==3 && !faultUsed) {
        faultUsed=true;offlineUntil=DateTime.now().add(const Duration(seconds:8));
        stats['faults']=1;stats['interruptedPath']=path;
        request.response.add(bytes.sublist(0,65536));await request.response.flush();
        final socket=await request.response.detachSocket(writeHeaders:true);socket.destroy();return;
      }
      request.response.add(bytes);stats['bytes']=(stats['bytes'] as int)+bytes.length;
      await request.response.close();
      if(response.statusCode<300 && (blob || request.method=='PUT')) {
        final key='${request.method} $path';completed[key]=(completed[key]??0)+1;
      }
    } catch(_) {
      try {request.response.statusCode=502;await request.response.close();} catch(_) {}
    }
  },onDone:()=>client.close(force:true));
  return server;
}
