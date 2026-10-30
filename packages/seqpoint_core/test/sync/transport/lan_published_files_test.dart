import 'dart:io';
import 'dart:convert';

import 'package:seqpoint_core/src/sync/transport/lan_file_source.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';

import 'package:seqpoint_core/src/util/result.dart';
import 'package:test/test.dart';

import 'lan_fixture.dart';

void main() {
  test('catalog bytes and listing sizes are frozen before any async caller resumes', () async {
    final owner = List.filled(43, 'a').join();
    final path = 'ops/$owner/202610-0001.log';
    final bytes = [1, 2, 3];
    final inventory = <String, List<int>>{path: bytes};
    final source = LanFileSource(owner, () => inventory, LanLimits());
    final reading = source.read(path);
    final listing = source.list('ops/$owner');
    bytes[0] = 99;
    inventory[path] = [99];
    final frozen = await reading;
    expect(frozen, [1, 2, 3]);
    final listed = jsonDecode(utf8.decode(await listing)) as List;
    expect(listed.single['size'], 3);
    expect(() => frozen[0] = 99, throwsUnsupportedError);
  });
  late LanFixture fixture;
  setUp(() async {
    fixture = LanFixture();
    await fixture.init();
  });
  tearDown(() => fixture.dispose());

  test(
    'unpublished on-disk files expose neither bytes nor listing metadata',
    () async {
      await File(
        '${fixture.directory(fixture.b).path}/${fixture.path(fixture.b)}',
      ).writeAsBytes([99]);
      final client = fixture.client();
      expect(await client.get(fixture.path(fixture.b)), isA<Err<List<int>>>());
      expect(
        (await client.list('ops/${fixture.b.deviceId}')).valueOrNull,
        isEmpty,
      );
    },
  );

  test(
    'a replaced on-disk file cannot replace trusted published bytes',
    () async {
      await fixture.write(fixture.b, [1, 2, 3]);
      await File(
        '${fixture.directory(fixture.b).path}/${fixture.path(fixture.b)}',
      ).writeAsBytes([99]);
      final client = fixture.client();
      expect((await client.get(fixture.path(fixture.b))).valueOrNull, [
        1,
        2,
        3,
      ]);
      expect(
        (await client.list('ops/${fixture.b.deviceId}'))
            .valueOrNull
            ?.single
            .size,
        3,
      );
    },
  );
}
