import 'dart:convert';
import 'dart:io';
import 'package:basic_utils/basic_utils.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:test/test.dart';
import 'package:seqpoint_core/src/crypto/lan_tls_identity.dart';

void main() {
  late LanTlsIdentity identity;
  setUpAll(() async => identity = await LanTlsIdentity.generate());
  test('generated identity reopens with SHA256 of certificate DER', () async {
    final der = base64Decode(identity.certificatePem
        .replaceAll('-----BEGIN CERTIFICATE-----', '')
        .replaceAll('-----END CERTIFICATE-----', '')
        .replaceAll(RegExp(r'\s'), ''));
    final digest = await Sha256().hash(der);
    expect(identity.fingerprint,
        digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
    final reopened = await LanTlsIdentity.fromPem(
      certificatePem: identity.certificatePem,
      privateKeyPem: identity.privateKeyPem,
    );
    expect(reopened.fingerprint, identity.fingerprint);
    expect(reopened.createSecurityContext(), isA<SecurityContext>());
    expect(identity.notBefore.isBefore(DateTime.now().toUtc()), isTrue);
    expect(identity.notAfter.isAfter(DateTime.now().toUtc()), isTrue);
  });
  test('rejects extra PEM blocks, junk, oversized and malformed material', () async {
    for (final certificate in [
      'junk${identity.certificatePem}',
      '${identity.certificatePem}\n${identity.certificatePem}',
      '${identity.certificatePem}\njunk',
      'x' * 16385,
      '-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----',
    ]) {
      await expectLater(LanTlsIdentity.fromPem(
        certificatePem: certificate, privateKeyPem: identity.privateKeyPem,
      ), throwsFormatException);
    }
    for (final key in [
      '${identity.privateKeyPem}\n${identity.privateKeyPem}',
      'private-test-value', 'x' * 8193,
    ]) {
      await expectLater(LanTlsIdentity.fromPem(
        certificatePem: identity.certificatePem, privateKeyPem: key,
      ), throwsA(predicate((e) => e is FormatException &&
          !e.toString().contains('private-test-value'))));
    }
  });
  test('rejects mismatched keys and invalid validity windows', () async {
    final other = await LanTlsIdentity.generate();
    await expectLater(LanTlsIdentity.fromPem(
      certificatePem: identity.certificatePem, privateKeyPem: other.privateKeyPem,
    ), throwsFormatException);
    for (final instant in [
      identity.notBefore.subtract(const Duration(seconds: 1)), identity.notAfter,
    ]) {
      await expectLater(LanTlsIdentity.fromPem(
        certificatePem: identity.certificatePem,
        privateKeyPem: identity.privateKeyPem, now: instant,
      ), throwsFormatException);
    }
  });
  test('rejects DER trailing bytes even if the certificate parser accepts them', () async {
    final der = base64Decode(identity.certificatePem
        .replaceAll(RegExp(r'-----[^\n]+-----|\s'), ''));
    final certificate = '-----BEGIN CERTIFICATE-----\n'
        '${base64Encode([...der, 0])}\n-----END CERTIFICATE-----';
    await expectLater(LanTlsIdentity.fromPem(
      certificatePem: certificate, privateKeyPem: identity.privateKeyPem,
    ), throwsFormatException);
  });
  test('rejects a fourth Certificate field inside its valid outer DER length', () async {
    final original = CryptoUtils.getBytesFromPEMString(identity.certificatePem);
    final der = [...original, 0x05, 0x00];
    _extendDerLength(der, 0, 2);
    await expectLater(LanTlsIdentity.fromPem(
      certificatePem: '-----BEGIN CERTIFICATE-----\n'
          '${base64Encode(der)}\n-----END CERTIFICATE-----',
      privateKeyPem: identity.privateKeyPem,
    ), throwsFormatException);
  });
  test('rejects wrong Certificate field tags and RSA signature unused bits', () async {
    final der = CryptoUtils.getBytesFromPEMString(identity.certificatePem);
    final tbs = 2 + (der[1] & 0x7f);
    final algorithm = _derEnd(der, tbs);
    final signature = _derEnd(der, algorithm);
    final signatureContent = signature + 2 + (der[signature + 1] & 0x7f);
    for (final change in [
      (tbs, 0x31), (algorithm, 0x31), (signature, 0x04),
      (signatureContent, 1), (signatureContent, 8), (signatureContent, 255),
    ]) {
      final malformed = List<int>.of(der)..[change.$1] = change.$2;
      await expectLater(LanTlsIdentity.fromPem(
        certificatePem: '-----BEGIN CERTIFICATE-----\n'
            '${base64Encode(malformed)}\n-----END CERTIFICATE-----',
        privateKeyPem: identity.privateKeyPem,
      ), throwsFormatException);
    }
  });
  test('rejects a parsed certificate whose algorithm fields fail native loading', () async {
    final original = CryptoUtils.getBytesFromPEMString(identity.certificatePem);
    final algorithm = _derEnd(original, 2 + (original[1] & 0x7f));
    final signature = _derEnd(original, algorithm);
    final der = [...original.take(signature), 0x05, 0x00,
      ...original.skip(signature)];
    _extendDerLength(der, algorithm, 2);
    _extendDerLength(der, 0, 2);
    await expectLater(LanTlsIdentity.fromPem(
      certificatePem: '-----BEGIN CERTIFICATE-----\n'
          '${base64Encode(der)}\n-----END CERTIFICATE-----',
      privateKeyPem: identity.privateKeyPem,
    ), throwsFormatException);
  });
  test('rejects weak keys, SHA1 certificates, oversized validity and bad signatures', () async {
    final key = CryptoUtils.rsaPrivateKeyFromPem(identity.privateKeyPem);
    final weak = CryptoUtils.generateRSAKeyPair(keySize: 1024).privateKey
        as RSAPrivateKey;
    for (final item in [
      (_certificate(key, digest: 'SHA-1'), identity.privateKeyPem),
      (_certificate(key, days: 367), identity.privateKeyPem),
      (_certificate(weak), CryptoUtils.encodeRSAPrivateKeyToPem(weak)),
    ]) {
      await expectLater(LanTlsIdentity.fromPem(
        certificatePem: item.$1, privateKeyPem: item.$2,
      ), throwsFormatException);
    }
    final der = CryptoUtils.getBytesFromPEMString(identity.certificatePem);
    der[der.length - 1] ^= 1;
    await expectLater(LanTlsIdentity.fromPem(
      certificatePem: '-----BEGIN CERTIFICATE-----\n'
          '${base64Encode(der)}\n-----END CERTIFICATE-----',
      privateKeyPem: identity.privateKeyPem,
    ), throwsFormatException);
  });
  test('PKCS12 HTTPS loopback serves only when the certificate pin matches', () async {
    final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4, 0, identity.createSecurityContext());
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write('verified');
      await request.response.close();
    }, onError: (Object _) {});
    String pin(X509Certificate cert) => const DartSha256().hashSync(cert.der)
        .bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (cert, host, port) =>
          pin(cert) == identity.fingerprint;
    addTearDown(() => client.close(force: true));
    final uri = Uri.parse('https://127.0.0.1:${server.port}/');
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 5));
    final response = await request.close().timeout(const Duration(seconds: 5));
    expect(await response.transform(utf8.decoder).join(), 'verified');
    final denied = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (cert, host, port) => pin(cert) == '0' * 64;
    addTearDown(() => denied.close(force: true));
    await expectLater(denied.getUrl(uri).timeout(const Duration(seconds: 5)),
        throwsA(isA<HandshakeException>()));
  });
  test('rejects internally valid RSA factors paired with the wrong private exponent', () async {
    final key = CryptoUtils.rsaPrivateKeyFromPem(identity.privateKeyPem);
    final malformed = RSAPrivateKey(key.modulus!, BigInt.from(65537), key.p, key.q);
    await expectLater(LanTlsIdentity.fromPem(
      certificatePem: identity.certificatePem,
      privateKeyPem: CryptoUtils.encodeRSAPrivateKeyToPem(malformed),
    ), throwsFormatException);
  });
  test('an identity that expires while held in memory cannot start a server', () async {
    final expired = await LanTlsIdentity.generate(
        now: DateTime.now().toUtc().subtract(const Duration(days: 400)));
    expect(expired.createSecurityContext, throwsStateError);
  });
}

String _certificate(RSAPrivateKey key,
    {String digest = 'SHA-256', int days = 365}) {
  final csr = X509Utils.generateRsaCsrPem({'CN': 'SeqPoint test'}, key,
      RSAPublicKey(key.modulus!, BigInt.from(65537)), signingAlgorithm: digest);
  return X509Utils.generateSelfSignedCertificate(key, csr, days,
      notBefore: DateTime.now().toUtc().subtract(const Duration(minutes: 1)));
}

void _extendDerLength(List<int> der, int offset, int added) {
  final lengthOffset = offset + 1;
  if (der[lengthOffset] < 128) {
    der[lengthOffset] += added;
    return;
  }
  final count = der[lengthOffset] & 0x7f;
  var carry = added;
  for (var i = lengthOffset + count; i > lengthOffset; i--) {
    carry += der[i];
    der[i] = carry & 0xff;
    carry >>= 8;
  }
  expect(carry, 0);
}

int _derEnd(List<int> der, int offset) {
  var length = der[offset + 1];
  offset += 2;
  if (length >= 128) {
    final count = length & 0x7f;
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | der[offset++];
    }
  }
  return offset + length;
}
