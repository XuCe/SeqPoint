import 'dart:convert';
import 'transport/lan_transport.dart';
import '../db/database.dart';
import 'sync_content_transfer.dart';
import 'sync_manifest.dart';
import 'sync_files.dart';
import 'sync_publisher.dart';
import 'sync_checkpoint_build.dart';
import 'sync_checkpoint_store.dart';
import 'sync_checkpoint_verify.dart';
import 'sync_checkpoint_stage.dart';
import 'sync_checkpoint_commit.dart';
import 'transport/lan_protocol.dart';
import 'transport/relay_transport.dart';

class SyncCheckpoints {
  SyncCheckpoints(this.db,SyncContentTransfer transfer,this.authorKeys):codec=transfer.codec,_transfer=transfer;
  SyncCheckpoints.local(this.db,this.codec,this.authorKeys):_transfer=null;
  final SeqDatabase db;
  final SyncContentTransfer? _transfer;
  final SyncManifestCodec codec;
  SyncContentTransfer get transfer=>_transfer ?? (throw StateError('Checkpoint transport unavailable'));
  final Map<String,List<int>> authorKeys;
  RelayTransport get relay=>transfer.client as RelayTransport;
  bool pending=false;
  final _deferRewrap=<String>{};
  int reclaimed=0,added=0;
  void guard()=>codec.blobs.files.guard?.call();
  Future<SyncManifest> stored(Map<String,Object?> row) async {
    final trusted=SyncManifestCodec(blobs:codec.blobs,keys:codec.keys,epoch:codec.epoch,
      membershipHash:codec.membershipHash,signers:authorKeys);
    return trusted.open(row['manifest_bytes'] as List<int>,expectedHash:row['manifest_hash'] as String);
  }
  Future<SyncManifest?> prepare(PublicationSnapshot? head) async {
    if(head==null) return null;
    if(!head.sealed || !head.published) throw StateError('Checkpoint needs sealed publication');
    final prior=db.raw.select('SELECT * FROM sync_checkpoints WHERE author=?',[codec.keys.deviceId]);
    final manifest=prior.isNotEmpty && prior.single['covered_seq']==head.seq
      ? await rewrapSyncCheckpoint(await stored(prior.single),codec)
      : await buildSyncCheckpoint(db,codec,head.seq,lanSha256(head.bytes));
    guard();
    if(manifest.anchor!=lanSha256(head.bytes)) throw StateError('Checkpoint head fork');
    await verifySyncCheckpoint(manifest,codec,authorKeys);guard();
    db.transaction(()=>storeSyncCheckpoint(db,manifest,floor:prior.isEmpty?0:prior.single['local_floor'] as int));
    return manifest;
  }
  Future<bool> publish(SyncManifest manifest,{PublicationSnapshot? head}) async {
    final path='checkpoints/${manifest.author}.json';
    final current=transfer.value(await relay.inventory([path]))[path]!; guard();
    if(current!=manifest.hash) {
      if(!await transfer.upload(manifest)) {pending=true;return false;}
      if(head!=null) {
        transfer.value(await relay.putChanged('ops/${manifest.author}/${head.fileName}',head.bytes));guard();
      }
    }
    final confirmed='cache/relay-confirmed-${manifest.hash}';
    if(current!=manifest.hash || !codec.blobs.files.file(confirmed).existsSync()) {
      reclaimed+=transfer.value(await relay.commitCheckpoint(author:manifest.author,
        previous:current,manifest:manifest.bytes,segment:head?.fileName??''));guard();
      await codec.blobs.files.write(confirmed,[1]);
    }
    compactLocal(manifest);
    return true;
  }
  void compactLocal(SyncManifest manifest) {
    guard();
    if(manifest.author==codec.keys.deviceId) {
      final floor=manifest.sequence-1;
      db.transaction(() {
        final obsolete=db.raw.select('SELECT file_name FROM sync_publications WHERE seq<=?',[floor]);
        for(final row in obsolete) {
          final file=SyncFiles(codec.blobs.files.root).file('ops/${manifest.author}/${row['file_name']}');
          if(file.existsSync()) file.deleteSync();
        }
        db.raw.execute('DELETE FROM sync_publications WHERE seq<=?',[floor]);
        pruneCheckpointFacts(db,manifest.author,floor);
        storeSyncCheckpoint(db,manifest,floor:floor);
      });
    }
  }
  Future<void> pull(String author) async {
    if(author==codec.keys.deviceId) return;
    final path='checkpoints/$author.json';
    final hash=transfer.value(await relay.inventory([path]))[path]!;guard();
    if(hash.isEmpty) return;
    final prior=db.raw.select('SELECT * FROM sync_checkpoints WHERE author=?',[author]);
    if(prior.isNotEmpty && prior.single['manifest_hash']==hash) return;
    final bytes=transfer.value(await transfer.client.get(path));guard();
    await accept(author,bytes,hash);
  }
  Future<void> accept(String author,List<int> bytes,String hash) async {
    if(author==codec.keys.deviceId) return;
    final prior=db.raw.select('SELECT * FROM sync_checkpoints WHERE author=?',[author]);
    if(prior.isNotEmpty && prior.single['manifest_hash']==hash) return;
    final envelope=jsonDecode(utf8.decode(bytes)) as Map;
    final header=jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(envelope['payload'] as String)))) as Map;
    if(header['sequence'] is int && (header['sequence'] as int)>(prior.isEmpty?0:prior.single['covered_seq'] as int)) {
      _deferRewrap.add(author);
    }
    if(header['epoch']!=codec.epoch || header['membership']!=codec.membershipHash) {pending=true;return;}
    final manifest=await codec.open(bytes,expectedHash:hash);guard();
    if(manifest.author!=author) throw const FormatException('Checkpoint author path mismatch');
    if(manifest.epoch!=codec.epoch || manifest.membershipHash!=codec.membershipHash) {
      pending=true;return;
    }
    await verifySyncCheckpoint(manifest,codec,authorKeys);
    if(prior.isNotEmpty && (prior.single['covered_seq'] as int)>manifest.sequence) {
      throw StateError('Relay checkpoint rolled back');
    }
    if(!await transfer.download(manifest)) {pending=true;return;}
    await stageSyncCheckpoint(db,manifest,codec.blobs);guard();
    added+=commitSyncCheckpoint(db,manifest,guard);
  }
  Future<void> pullLan() async {
    final client=transfer.client as LanTransport;
    final path='checkpoints/${client.peer.deviceId}';
    final files=transfer.value(await client.list(path));guard();
    for(final file in files) {
      final bytes=transfer.value(await client.get('$path/${file.name}'));guard();
      await accept(file.name.substring(0,file.name.length-5),bytes,lanSha256(bytes));
    }
  }
  Future<void> rewrapStored({bool publishToRelay=true}) async {
    final rows=db.raw.select('SELECT * FROM sync_checkpoints WHERE author<>? ORDER BY author',[codec.keys.deviceId]);
    for(final row in rows) {
      if(publishToRelay && _deferRewrap.contains(row['author'])) continue;
      final old=await stored(row);guard();
      final manifest=await rewrapSyncCheckpoint(old,codec);guard();
      if(manifest.hash==old.hash) continue;
      await verifySyncCheckpoint(manifest,codec,authorKeys);guard();
      if(publishToRelay && !await publish(manifest)) return;
      db.transaction(()=>storeSyncCheckpoint(db,manifest,floor:row['local_floor'] as int));
    }
  }
}
