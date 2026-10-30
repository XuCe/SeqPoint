import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/src/sync/transport/lan_file_source.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';
import 'package:test/test.dart';

import 'lan_fixture.dart';

void main() {
  late LanFixture fixture;
  late LanFileSource source;
  setUp(() async {
    fixture = LanFixture();
    await fixture.init();
    source = LanFileSource(
      fixture.b.deviceId,
      () => fixture.publications[fixture.b.deviceId]!,
      LanLimits(),
    );
  });
  tearDown(() => fixture.dispose());

  test('only owner ACK, member and snapshot names are listed', () async {
    for (final dir in ['members', 'acks', 'snapshots']) {
      final suffix = dir == 'snapshots' ? '-1.snap' : '.json';
      fixture.publications[fixture
          .b
          .deviceId]!['$dir/${fixture.b.deviceId}$suffix'] = [
        1,
      ];
      fixture.publications[fixture
          .b
          .deviceId]!['$dir/${fixture.a.deviceId}$suffix'] = [
        99,
      ];
      await File(
        '${fixture.directory(fixture.b).path}/$dir/${fixture.b.deviceId}$suffix',
      ).writeAsString('self');
      await File(
        '${fixture.directory(fixture.b).path}/$dir/${fixture.a.deviceId}$suffix',
      ).writeAsString('other');
      final entries = jsonDecode(utf8.decode(await source.list(dir))) as List;
      expect(entries.single['name'], '${fixture.b.deviceId}$suffix');
    }
  });

  test(
    'symbolic files and ancestor directories supply no catalog data',
    () async {
      final outside = await File('${fixture.root.path}/outside')
          .writeAsString('secret');
      await Link(
        '${fixture.directory(fixture.b).path}/${fixture.path(fixture.b)}',
      ).create(outside.path);
      await expectLater(source.read(fixture.path(fixture.b)), throwsStateError);
      await Link(
        '${fixture.directory(fixture.b).path}/${fixture.path(fixture.b)}',
      ).delete();
      final ops = Directory(
        '${fixture.directory(fixture.b).path}/ops/${fixture.b.deviceId}',
      );
      await ops.delete();
      await Link(ops.path).create(fixture.root.path);
      expect(
        jsonDecode(utf8.decode(await source.list('ops/${fixture.b.deviceId}'))),
        isEmpty,
      );
    },
  );
  test(
    'file replacement after a read starts cannot substitute outside bytes',
    () async {
      await fixture.write(fixture.b, [1, 2, 3]);
      final file = File(
        '${fixture.directory(fixture.b).path}/${fixture.path(fixture.b)}',
      );
      final outside = await File('${fixture.root.path}/outside')
          .writeAsBytes([99]);
      final reading = source.read(fixture.path(fixture.b));
      await file.delete();
      await Link(file.path).create(outside.path);
      expect(await reading, [1, 2, 3]);
      expect(await source.read(fixture.path(fixture.b)), [1, 2, 3]);
    },
  );

  test('file sizes and listing counts are bounded before serialization', () async {
    await fixture.write(fixture.b, [1, 2, 3]);
    final small = LanFileSource(
      source.owner,
      source.publishedFiles,
      LanLimits(maxFileBytes: 2),
    );
    await expectLater(small.read(fixture.path(fixture.b)), throwsStateError);
    await expectLater(
      small.list('ops/${fixture.b.deviceId}'),
      throwsStateError,
    );
    await File(
      '${fixture.directory(fixture.b).path}/ops/${fixture.b.deviceId}/202610-0002.log',
    ).writeAsBytes([1]);
    fixture.publications[fixture
        .b
        .deviceId]!['ops/${fixture.b.deviceId}/202610-0002.log'] = [
      1,
    ];
    final one = LanFileSource(
      source.owner,
      source.publishedFiles,
      LanLimits(maxFiles: 1),
    );
    await expectLater(one.list('ops/${fixture.b.deviceId}'), throwsStateError);
  });
}
