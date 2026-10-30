import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';
import 'package:test/test.dart';
import 'relay_node_fixture.dart';

void main() {
  test('v2 relay reuses immutable content and detects changed tails', () async {
    final f=RelayNodeFixture(); await f.init(); addTearDown(f.close);
    final client=f.client(f.runtime.a); addTearDown(client.close);
    final bytes=List.filled(1024,42);
    final path='blobs/${client.selfDeviceId}/${lanSha256(bytes)}.bin';
    expect((await client.putChanged(path,bytes) as Ok<bool>).value,isTrue);
    expect((await client.putChanged(path,bytes) as Ok<bool>).value,isFalse);
    expect((await client.get(path) as Ok<List<int>>).value,bytes);
    final tail='ops/${client.selfDeviceId}/202610-0001.log';
    expect((await client.putChanged(tail,[1]) as Ok<bool>).value,isTrue);
    expect((await client.putChanged(tail,[2]) as Ok<bool>).value,isTrue);
    final page=await client.listPage('ops/${client.selfDeviceId}');
    expect(page.isOk,isTrue);
  },skip:Platform.environment['SEQPOINT_NODE_BINARY']==null?'Set node binary':false);
}
