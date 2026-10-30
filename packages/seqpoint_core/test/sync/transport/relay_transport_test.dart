import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('relay rejects plaintext, credentials, paths and fragments', () async {
    final keys = await DeviceKeys.fromSeeds(
      List.filled(32, 1),
      List.filled(32, 2),
    );
    for (final endpoint in [
      'http://example.com',
      'https://user@host',
      'https://host/api',
      'https://host#secret',
      'https://host?q=x',
    ]) {
      expect(
        () => RelayTransport(
          endpoint: endpoint,
          vaultPublicId: 'v' * 43,
          keys: keys,
        ),
        throwsArgumentError,
      );
    }
  });
}
