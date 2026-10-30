import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:test/test.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';

import 'lan_fixture.dart';

class _GateCrypto extends DartCryptography {
  final entered = Completer<void>(), release = Completer<void>();
  List<int>? target;
  @override
  Sha256 sha256() => _GateHash(this);
}

class _GateHash extends DartSha256 {
  _GateHash(this.gate);
  final _GateCrypto gate;
  @override
  Future<Hash> hash(List<int> input) async {
    if (!gate.entered.isCompleted &&
        input.toString() == gate.target.toString()) {
      gate.entered.complete();
      await gate.release.future;
    }
    return super.hash(input);
  }
}

void main() {
  test(
    'client drain waits raw response verification after transfer timeout',
    () async {
      final fixture = LanFixture();
      await fixture.init();
      addTearDown(fixture.dispose);
      final original = Cryptography.instance, gate = _GateCrypto();
      Cryptography.instance = gate;
      addTearDown(() {
        Cryptography.instance = original;
      });
      addTearDown(() {
        if (!gate.release.isCompleted) gate.release.complete();
      });
      gate.target = fixture.b.signer.publicKey;
      final client = fixture.client(
        limits: LanLimits(timeout: const Duration(seconds: 1)),
      );
      final request = client.list('members');
      await gate.entered.future.timeout(const Duration(seconds: 2));
      await request;
      var closed = false;
      final closing = client.closeAndDrain().then((_) {
        closed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      gate.release.complete();
      await closing;
    },
  );
  test(
    'server close drains raw verification even after request timeout',
    () async {
      final fixture = LanFixture();
      await fixture.init(
        limits: LanLimits(timeout: const Duration(milliseconds: 20)),
      );
      addTearDown(fixture.dispose);
      final original = Cryptography.instance, gate = _GateCrypto();
      Cryptography.instance = gate;
      addTearDown(() {
        Cryptography.instance = original;
      });
      addTearDown(() {
        if (!gate.release.isCompleted) gate.release.complete();
      });
      gate.target = fixture.a.signer.publicKey;
      final request = fixture.client().list('members');
      await gate.entered.future;
      await request;
      var closed = false;
      final closing = fixture.serverB.close().then((_) {
        closed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      gate.release.complete();
      await closing;
    },
  );
  test('server close drains accepted verification before returning', () async {
    final fixture = LanFixture();
    await fixture.init();
    addTearDown(fixture.dispose);
    final original = Cryptography.instance, gate = _GateCrypto();
    Cryptography.instance = gate;
    addTearDown(() {
      Cryptography.instance = original;
    });
    gate.target = fixture.a.signer.publicKey;
    final request = fixture.client().list('members');
    await gate.entered.future;
    var closed = false;
    final closing = fixture.serverB.close().then((_) {
      closed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    gate.release.complete();
    await closing;
    await request;
  });
}
