import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';
import 'package:cryptography/cryptography.dart';

/// 本机专用自签名服务证书；私钥只在内存与系统安全记录中流转。
/// 自签名不受系统信任；对端须以固定的 SHA256 DER 指纹认证。
class LanTlsIdentity {
  const LanTlsIdentity._(this.certificatePem, this.privateKeyPem,
      this.fingerprint, this.notBefore, this.notAfter);

  final String certificatePem;
  final String privateKeyPem;
  final String fingerprint;
  final DateTime notBefore;
  final DateTime notAfter;

  static Future<LanTlsIdentity> generate({DateTime? now}) async {
    final instant = (now ?? DateTime.now()).toUtc();
    return Isolate.run(() async {
      final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
      final privateKey = pair.privateKey as RSAPrivateKey;
      final publicKey = pair.publicKey as RSAPublicKey;
      final csr = X509Utils.generateRsaCsrPem(
          {'CN': 'SeqPoint LAN'}, privateKey, publicKey,
          signingAlgorithm: 'SHA-256');
      final random = Random.secure();
      final serial = BigInt.parse(List.generate(16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join(),
          radix: 16) + BigInt.one;
      final certificate = X509Utils.generateSelfSignedCertificate(
        privateKey, csr, 365,
        serialNumber: serial.toString(), cA: false,
        extKeyUsage: [ExtendedKeyUsage.SERVER_AUTH],
        notBefore: instant.subtract(const Duration(minutes: 5)),
      );
      return fromPem(certificatePem: certificate,
          privateKeyPem: CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
          now: instant);
    });
  }

  static Future<LanTlsIdentity> fromPem({
    required String certificatePem,
    required String privateKeyPem,
    DateTime? now,
  }) async {
    try {
      if (certificatePem.length > 16384 || privateKeyPem.length > 8192) {
        throw const FormatException();
      }
      final der = _pemDer(certificatePem, 'CERTIFICATE');
      _validateCertificateDer(der);
      final keyDer = _pemDer(privateKeyPem, 'PRIVATE KEY');
      final certificate = X509Utils.x509CertificateFromPem(certificatePem);
      final tbs = certificate.tbsCertificate!;
      final key = CryptoUtils.rsaPrivateKeyFromPem(privateKeyPem);
      final valid = tbs.validity;
      final instant = (now ?? DateTime.now()).toUtc();
      if (certificate.signatureAlgorithm != '1.2.840.113549.1.1.11' ||
          tbs.signatureAlgorithm != certificate.signatureAlgorithm ||
          tbs.subjectPublicKeyInfo.algorithm != '1.2.840.113549.1.1.1' ||
          tbs.version != 3 || tbs.serialNumber <= BigInt.zero ||
          tbs.subject.length != tbs.issuer.length ||
          tbs.subject.entries.any((e) => tbs.issuer[e.key] != e.value) ||
          key.modulus!.bitLength != 2048 ||
          key.publicExponent != BigInt.from(65537) ||
          tbs.subjectPublicKeyInfo.exponent != 65537 ||
          X509Utils.getModulusFromRSAX509Pem(certificatePem) != key.modulus ||
          valid.notBefore.isAfter(instant) || !valid.notAfter.isAfter(instant) ||
          valid.notAfter.difference(valid.notBefore) > const Duration(days: 366) ||
          !X509Utils.checkX509Signature(certificatePem)) {
        throw const FormatException();
      }
      final encodedKey = base64Encode(keyDer);
      if (encodedKey != base64Encode(CryptoUtils.getBytesFromPEMString(
          CryptoUtils.encodeRSAPrivateKeyToPem(key)))) {
        throw const FormatException();
      }
      final digest = await Sha256().hash(der);
      final identity = LanTlsIdentity._(certificatePem, privateKeyPem,
          digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          valid.notBefore.toUtc(), valid.notAfter.toUtc());
      identity._createSecurityContext();
      return identity;
    } catch (_) {
      throw const FormatException('本机 TLS 证书或私钥无效');
    }
  }

  SecurityContext createSecurityContext() {
    final now = DateTime.now().toUtc();
    if (notBefore.isAfter(now) || !notAfter.isAfter(now)) {
      throw StateError('本机 TLS 证书不在有效期内');
    }
    return _createSecurityContext();
  }

  SecurityContext _createSecurityContext() {
    final random = Random.secure();
    final password = base64Encode(
        List.generate(24, (_) => random.nextInt(256)));
    // iOS 要求 PKCS12；此库 MAC 派生固定 20 字节，保持默认 SHA1 兼容封装。
    // 封装和随机密码仅驻内存；TLS 证书及其指纹均使用 SHA256。
    final bytes = Pkcs12Utils.generatePkcs12(privateKeyPem, [certificatePem],
        password: password, certPbe: 'PBE-SHA1-3DES');
    return SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
      ..useCertificateChainBytes(bytes, password: password)
      ..usePrivateKeyBytes(bytes, password: password);
  }

  static Uint8List _pemDer(String pem, String label) {
    final match = RegExp('^-----BEGIN $label-----\\r?\\n'
        '([A-Za-z0-9+/=\\r\\n]+)\\r?\\n-----END $label-----\\r?\\n?\$')
        .firstMatch(pem);
    if (match == null) throw const FormatException();
    final encoded = match.group(1)!.replaceAll(RegExp(r'[\r\n]'), '');
    final der = base64Decode(encoded);
    if (base64Encode(der) != encoded) throw const FormatException();
    final field = _derField(der, 0);
    if (field.tag != 0x30 || field.end != der.length) {
      throw const FormatException();
    }
    return der;
  }

  static ({int tag, int content, int end}) _derField(Uint8List der, int offset) {
    if (offset < 0 || offset + 2 > der.length) throw const FormatException();
    final tag = der[offset++];
    var length = der[offset++];
    if (length >= 128) {
      final count = length & 0x7f;
      if (count < 1 || count > 3 || offset + count > der.length ||
          der[offset] == 0) {
        throw const FormatException();
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | der[offset++];
      }
      if (length < 128) throw const FormatException();
    }
    final end = offset + length;
    if (end > der.length) throw const FormatException();
    return (tag: tag, content: offset, end: end);
  }

  static void _validateCertificateDer(Uint8List der) {
    final outer = _derField(der, 0);
    final tbs = _derField(der, outer.content);
    final algorithm = _derField(der, tbs.end);
    final signature = _derField(der, algorithm.end);
    if (tbs.tag != 0x30 || algorithm.tag != 0x30 || signature.tag != 0x03 ||
        signature.end != outer.end || signature.end - signature.content != 257 ||
        der[signature.content] != 0) {
      throw const FormatException();
    }
  }
}
