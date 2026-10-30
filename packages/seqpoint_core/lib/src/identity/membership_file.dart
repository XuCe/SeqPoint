import 'dart:convert';

import 'membership_state.dart';
import 'pairing_transcript.dart' show parsePairingBytes;

/// Public signed facts; this file never creates a trusted membership anchor.
final class MembershipFile {
  MembershipFile({
    required this.vaultPublicId,
    required this.authorityId,
    required this.issuerDeviceId,
    required List<MembershipEvent> events,
  }) : events = List.unmodifiable(events) {
    parsePairingBytes(issuerDeviceId, 32);
    parsePairingBytes(authorityId, 32);
    if (events.length > maxEvents) throw const FormatException('成员事件数量超限');
    if (RegExp(r'^[A-Za-z0-9_-]{1,128}$').firstMatch(vaultPublicId)?.end !=
        vaultPublicId.length) {
      throw const FormatException('成员文件Vault格式无效');
    }
    if (events.any(
      (event) =>
          event.issuerDeviceId != issuerDeviceId ||
          event.vaultPublicId != vaultPublicId ||
          event.authorityId != authorityId,
    )) {
      throw const FormatException('成员文件签发者或授权域不匹配');
    }
    final ids = <String>{};
    var sequence = 0;
    for (final event in events) {
      if (!ids.add(event.eventId) ||
          event.issuerSequence <= sequence ||
          event.envelopes.length > maxRecipients ||
          utf8.encode(jsonEncode(event.toJson())).length > maxEventBytes) {
        throw const FormatException('成员事件顺序、身份或大小无效');
      }
      sequence = event.issuerSequence;
    }
    if (encode().length > maxFileBytes) throw const FormatException('成员文件过大');
  }

  static const maxFileBytes = 1024 * 1024;
  static const maxEvents = 256;
  static const maxEventBytes = 256 * 1024;
  static const maxRecipients = 256;
  final String vaultPublicId, authorityId, issuerDeviceId;
  final List<MembershipEvent> events;
  String get path => 'members/$issuerDeviceId.json';

  void validateExtensionOf(MembershipFile previous) {
    if (vaultPublicId != previous.vaultPublicId ||
        authorityId != previous.authorityId ||
        issuerDeviceId != previous.issuerDeviceId ||
        events.length < previous.events.length) {
      throw StateError('成员文件历史被截断或更换');
    }
    for (var i = 0; i < previous.events.length; i++) {
      if (jsonEncode(events[i].toJson()) !=
          jsonEncode(previous.events[i].toJson())) {
        throw StateError('成员文件历史前缀改变');
      }
    }
  }

  List<int> encode() => List.unmodifiable(
    utf8.encode(
      jsonEncode({
        'purpose': 'seqpoint-membership-file-v1',
        'v': 1,
        'vault_id': vaultPublicId,
        'authority_id': authorityId,
        'issuer_id': issuerDeviceId,
        'events': [for (final event in events) event.toJson()],
      }),
    ),
  );

  static MembershipFile decode(
    List<int> bytes, {
    required String issuerFileDeviceId,
    required String expectedVaultPublicId,
    required String expectedAuthorityId,
  }) {
    try {
      if (bytes.isEmpty ||
          bytes.length > maxFileBytes ||
          bytes.any((byte) => byte < 0 || byte > 255)) {
        throw const FormatException();
      }
      final json = jsonDecode(utf8.decode(bytes));
      const fields = {
        'purpose',
        'v',
        'vault_id',
        'authority_id',
        'issuer_id',
        'events',
      };
      if (json is! Map ||
          json.length != fields.length ||
          json.keys.any((key) => !fields.contains(key)) ||
          json['purpose'] != 'seqpoint-membership-file-v1' ||
          json['v'] is! int ||
          json['v'] != 1 ||
          json['vault_id'] != expectedVaultPublicId ||
          json['authority_id'] != expectedAuthorityId ||
          json['issuer_id'] != issuerFileDeviceId ||
          json['events'] is! List ||
          (json['events'] as List).length > maxEvents) {
        throw const FormatException();
      }
      final events = <MembershipEvent>[];
      for (final raw in json['events'] as List) {
        if (raw is! Map ||
            utf8.encode(jsonEncode(raw)).length > maxEventBytes ||
            raw['envelopes'] is! List ||
            (raw['envelopes'] as List).length > maxRecipients) {
          throw const FormatException();
        }
        events.add(MembershipEvent.fromJson(Map<String, Object?>.from(raw)));
      }
      final file = MembershipFile(
        vaultPublicId: expectedVaultPublicId,
        authorityId: expectedAuthorityId,
        issuerDeviceId: issuerFileDeviceId,
        events: events,
      );
      if (utf8.decode(bytes) != utf8.decode(file.encode())) {
        throw const FormatException('成员文件不是规范编码');
      }
      return file;
    } catch (_) {
      throw const FormatException('成员文件格式或签发者无效');
    }
  }

  Future<List<MembershipApplyResult>> ingestInto(
    MembershipReducer reducer,
  ) async {
    if (reducer.state.vaultPublicId != vaultPublicId ||
        reducer.state.authorityId != authorityId) {
      throw StateError('成员文件与可信授权域不匹配');
    }
    final results = <MembershipApplyResult>[];
    for (final event in events) {
      results.add(
        await reducer.ingest(event, issuerFileDeviceId: issuerDeviceId),
      );
    }
    return List.unmodifiable(results);
  }
}
