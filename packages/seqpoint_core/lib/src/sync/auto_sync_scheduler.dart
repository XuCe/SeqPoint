import 'dart:async';
import 'dart:math';

class AutoSyncScheduler {
  AutoSyncScheduler({required this.revision,required this.canRun,required this.work,
    DateTime Function()? now,double Function()? jitter,this.onError,
    this.idleInterval=const Duration(seconds:60)})
    : now=now??DateTime.now,jitter=jitter??(()=>0.8+Random().nextDouble()*0.4);
  Duration idleInterval;
  final String? Function() revision;
  final bool Function() canRun;
  final Future<bool> Function() work;
  final DateTime Function() now;
  final double Function() jitter;
  final void Function(Object)? onError;
  Timer? _timer;
  Future<void>? _flight;
  String? _revision;
  DateTime? _due,_dirtySince,_retryAt;
  bool _closed=false,_suspended=true;
  int _failures=0;
  Future<void> get settled=>_flight??Future<void>.value();
  void start({bool periodic=true}) {
    if(_closed) return;_suspended=false;_revision=revision();_due=now();
    _timer?.cancel();if(periodic) _timer=Timer.periodic(const Duration(seconds:1),(_)=>tick());
  }
  void request() {if(!_closed) _due=now();}
  void suspend() {_suspended=true;_timer?.cancel();_timer=null;}
  Future<void> stop() {_closed=true;suspend();return settled;}
  void tick() {
    if(_closed || _suspended) return;
    final time=now(),current=revision();
    if(current!=null && current!=_revision) {
      _revision=current;_dirtySince??=time;
      final latest=_dirtySince!.add(const Duration(seconds:10)),quiet=time.add(const Duration(seconds:2));
      _due=quiet.isBefore(latest)?quiet:latest;
    }
    if(_flight!=null || !canRun() || _due==null || time.isBefore(_due!) || (_retryAt!=null && time.isBefore(_retryAt!))) return;
    _due=null;_dirtySince=null;_flight=Future<void>.microtask(_execute).whenComplete(()=>_flight=null);
  }
  Future<void> _execute() async {
    try {
      final pending=await work();_failures=0;_retryAt=null;
      _due??=now().add(pending ? const Duration(seconds:2) : idleInterval);
    } catch(error) {
      _failures=(_failures+1).clamp(1,7);
      _retryAt=now().add(Duration(milliseconds:min(300000,max(5000,min(300,5*(1<<(_failures-1)))*1000*jitter())).round()));
      _due??=_retryAt;onError?.call(error);
    }
  }
}
