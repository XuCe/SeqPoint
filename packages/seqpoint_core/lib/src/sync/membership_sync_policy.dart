import '../identity/membership_state.dart';

enum MembershipSyncDecision { allowed, waiting, rejected }

final class MembershipSyncCheck {
  const MembershipSyncCheck._(this.decision, this.reason);
  final MembershipSyncDecision decision;
  final String reason;
  bool get isAllowed => decision == MembershipSyncDecision.allowed;
}

/// Business authorization is checked separately from crypto and durable ACKs.
final class MembershipSyncPolicy {
  MembershipSyncPolicy({
    required this.membership,
    required this.localDeviceId,
    required this.hasEpochKey,
  });
  final MembershipReducer membership;
  final String localDeviceId;

  /// Reports locally verified keys, never availability claimed by remote files.
  final bool Function(int epoch) hasEpochKey;
  static const _allowed = MembershipSyncCheck._(
    MembershipSyncDecision.allowed,
    'authorized',
  );

  MembershipSyncCheck checkSession(String peerDeviceId) {
    if (membership.isConflicted) return _reject('conflict');
    if (!membership.isMemberAuthorized(localDeviceId)) {
      return _reject('local-not-member');
    }
    if (peerDeviceId == localDeviceId) return _reject('local-peer');
    if (!membership.isMemberAuthorized(peerDeviceId)) {
      return _reject('peer-not-member');
    }
    return _allowed;
  }

  MembershipSyncCheck checkInbound({
    required String peerDeviceId,
    required int keyEpoch,
  }) {
    if (membership.isConflicted) return _reject('conflict');
    if (!membership.isMemberAuthorized(localDeviceId)) {
      return _reject('local-not-member');
    }
    if (keyEpoch < 1) return _reject('invalid-epoch');
    if (peerDeviceId == localDeviceId) return _reject('local-peer');
    if (keyEpoch < membership.state.epoch &&
        (membership.knownMemberKeys(peerDeviceId) != null ||
            membership.state.revokedIds.contains(peerDeviceId))) {
      return _wait('history-cutoff-unproven');
    }
    final session = checkSession(peerDeviceId);
    if (!session.isAllowed) return session;
    if (keyEpoch > membership.state.epoch) return _wait('future-epoch');
    if (!hasEpochKey(keyEpoch)) return _wait('epoch-key-unavailable');
    return _allowed;
  }

  MembershipSyncCheck checkOutbound({
    required String peerDeviceId,
    required int keyEpoch,
  }) {
    final session = checkSession(peerDeviceId);
    return session.isAllowed
        ? checkLocalPublication(keyEpoch: keyEpoch)
        : session;
  }

  MembershipSyncCheck checkLocalPublication({required int keyEpoch}) {
    if (membership.isConflicted) return _reject('conflict');
    if (!membership.isMemberAuthorized(localDeviceId)) {
      return _reject('local-not-member');
    }
    if (keyEpoch != membership.state.epoch) {
      return _reject('publication-epoch-mismatch');
    }
    return hasEpochKey(keyEpoch) ? _allowed : _wait('epoch-key-unavailable');
  }

  static MembershipSyncCheck _wait(String reason) =>
      MembershipSyncCheck._(MembershipSyncDecision.waiting, reason);
  static MembershipSyncCheck _reject(String reason) =>
      MembershipSyncCheck._(MembershipSyncDecision.rejected, reason);
}
