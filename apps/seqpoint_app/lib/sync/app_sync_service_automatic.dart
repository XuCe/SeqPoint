part of 'app_sync_service.dart';

extension _AppSyncAutomatic on AppSyncService {
  Future<void> _startAutomatic() async {
    if(_closed || _automaticStarted) return;
    _automaticStarted=true;
    try {
      final preferences=await SharedPreferences.getInstance();
      if(_closed) return;
      _automaticEnabled=preferences.getBool('sync.auto.enabled')??true;
      _userPaused=preferences.getBool('sync.user.paused')??false;
      final local=db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
      if(local['device_id'] is! String || local['enabled']!=1 || local['requires_new_identity']!=0) return;
      if(!prepared) await prepare('本机');
      await _refreshAutomaticTarget();
    } catch(_) {
      if(!_closed) { _error='自动同步未启动，请检查同步身份和安全存储';_notifyAutomatic(); }
    }
  }
  Future<void> _refreshAutomaticTarget() async {
    if(_closed || !_automaticStarted || !canSync) return;
    final vault=relayVaultId,endpoint=await loadRelayEndpoint();
    if(_closed || vault!=relayVaultId) return;
    _automaticEndpoint=endpoint;
    _automatic??=AutoSyncScheduler(revision:() {
      if(_closed || !db.raw.autocommit) return null;
      final row=db.raw.select('SELECT hlc_millis,hlc_counter,media_enabled FROM sync_local WHERE id=1').single;
      return '${row['hlc_millis']}:${row['hlc_counter']}:${row['media_enabled']}';
    },canRun:()=>!_closed && !_busy && !_userPaused && !_suspended && _automaticEnabled && canSync && _automaticEndpoint.isNotEmpty,
      work:() async {
        await syncRelay(automatic:true);
        return (_runtime?.mediaPending??false) && (_runtime?.mediaTransferredBytes??0)>0;
      });
    if(!_userPaused && !_suspended) _automatic!.start();
    _notifyAutomatic();
  }
}
