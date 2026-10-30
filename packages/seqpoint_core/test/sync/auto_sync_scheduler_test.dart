import 'dart:async';
import 'package:seqpoint_core/src/sync/auto_sync_scheduler.dart';
import 'package:test/test.dart';

void main() {
  test('debounces edits, never overlaps and drains before stop',() async {
    var now=DateTime.utc(2026),revision='0',calls=0;
    Completer<bool>? blocked;
    final scheduler=AutoSyncScheduler(now:()=>now,revision:()=>revision,canRun:()=>true,
      work:() async {calls++;return blocked==null?false:await blocked.future;});
    scheduler.start(periodic:false);scheduler.tick();await scheduler.settled;expect(calls,1);
    revision='1';scheduler.tick();now=now.add(const Duration(seconds:1));revision='2';scheduler.tick();
    expect(calls,1);now=now.add(const Duration(seconds:2));blocked=Completer<bool>();scheduler.tick();
    await Future<void>.delayed(Duration.zero);expect(calls,2);
    revision='3';now=now.add(const Duration(seconds:10));scheduler.tick();expect(calls,2);
    final stopping=scheduler.stop();blocked.complete(true);await stopping;
    now=now.add(const Duration(minutes:10));scheduler.tick();expect(calls,2);
  });
  test('failures back off; pending chunks continue; pause suppresses network',() async {
    var now=DateTime.utc(2026),calls=0,allowed=true;
    final scheduler=AutoSyncScheduler(now:()=>now,revision:()=>'0',canRun:()=>allowed,jitter:()=>1,
      work:() async {calls++;if(calls<3) throw StateError('offline');return calls==3;});
    scheduler.start(periodic:false);scheduler.tick();await scheduler.settled;expect(calls,1);
    now=now.add(const Duration(seconds:4));scheduler.tick();expect(calls,1);
    now=now.add(const Duration(seconds:1));scheduler.tick();await scheduler.settled;expect(calls,2);
    now=now.add(const Duration(seconds:9));scheduler.tick();expect(calls,2);
    now=now.add(const Duration(seconds:1));scheduler.tick();await scheduler.settled;expect(calls,3);
    allowed=false;now=now.add(const Duration(seconds:2));scheduler.tick();expect(calls,3);
    allowed=true;scheduler.tick();await scheduler.settled;expect(calls,4);
    await scheduler.stop();
  });
}
