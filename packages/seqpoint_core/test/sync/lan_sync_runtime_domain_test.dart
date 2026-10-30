import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';

void main() {
  test(
    'runtime remains bound to initial authority across pause and resume',
    () async {
      final f = RuntimeFixture(), other = RuntimeFixture();
      await f.init();
      await other.init();
      addTearDown(f.dispose);
      addTearDown(other.dispose);
      await f.start();
      await f.b.runtime.pause();
      f.b.membership = other.b.membership;
      f.b.version = Object();
      f.b.runtime.resume();
      await expectLater(
        f.b.runtime.startServer(
          securityContext: runtimeTlsContext(),
          tlsFingerprint: f.pin,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'existing root manifest from another vault cannot be silently reused',
    () async {
      final f = RuntimeFixture();
      await f.init();
      addTearDown(f.dispose);
      final manifest = File('${f.b.directory.path}/vault/manifest.json');
      await manifest.parent.create(recursive: true);
      await manifest.writeAsString(
        jsonEncode({
          'format_version': 1,
          'vault_public_id': 'another-vault',
          'key_epoch': 1,
        }),
      );
      await expectLater(
        f.b.runtime.startServer(
          securityContext: runtimeTlsContext(),
          tlsFingerprint: f.pin,
        ),
        throwsStateError,
      );
    },
  );
}
