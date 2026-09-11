/// A password-authenticated key exchange, used to authenticate device pairing.
///
/// Two parties that share a low-entropy secret run one [PakeSession] each and
/// end up with the same strong [PakeResult.sharedSecret]; an active attacker
/// who does not know the secret gets at most one online guess per run. The
/// default implementation is SPAKE2 (RFC 9382) in `conclave_crypto`.
///
/// The exchange is one round trip: the initiator sends [PakeSession.message]
/// first, the responder replies with its own, then each side calls
/// [PakeSession.finish] with the peer's message and exchanges the confirmation
/// MACs.
abstract interface class Pake {
  /// Begins a run.
  ///
  /// [initiator] is the side that sends first. [secret] is the shared
  /// low-entropy secret as raw bytes (the pairing code). [initiatorId] and
  /// [responderId] are fixed role labels mixed into the transcript; both sides
  /// must pass identical values.
  PakeSession start({
    required bool initiator,
    required List<int> secret,
    List<int> initiatorId = const [],
    List<int> responderId = const [],
  });
}

/// One party's state within a single [Pake] run. Not reusable.
abstract interface class PakeSession {
  /// This party's outbound message. Send it to the peer.
  List<int> get message;

  /// Consumes the peer's message and derives the shared secret and the two
  /// confirmation MACs. Call exactly once.
  ///
  /// Throws if the peer's message is malformed.
  PakeResult finish(List<int> peerMessage);
}

/// The output of a completed [Pake] run.
class PakeResult {
  /// Creates a completed exchange result.
  const PakeResult({
    required this.sharedSecret,
    required this.localConfirmation,
    required this.expectedPeerConfirmation,
  });

  /// The strong shared secret. Both sides derive the same bytes only if they
  /// used the same PAKE secret.
  final List<int> sharedSecret;

  /// This party's key-confirmation MAC. Send it to the peer.
  final List<int> localConfirmation;

  /// The MAC the peer must send back. Compare in constant time; a mismatch
  /// means the secrets differed (wrong pairing code) or the exchange was
  /// tampered with.
  final List<int> expectedPeerConfirmation;
}
