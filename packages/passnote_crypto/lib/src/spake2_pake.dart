import 'package:passnote/passnote.dart';

import 'spake2.dart';

/// [Pake] backed by SPAKE2 (RFC 9382), the default for device pairing.
///
/// Maps the port's initiator/responder roles onto SPAKE2's prover ("A") and
/// verifier ("B"): the initiator is the prover and sends first.
class Spake2Pake implements Pake {
  /// Creates the adapter.
  const Spake2Pake();

  @override
  PakeSession start({
    required bool initiator,
    required List<int> secret,
    List<int> initiatorId = const [],
    List<int> responderId = const [],
  }) {
    final run = Spake2.start(
      role: initiator ? Spake2Role.prover : Spake2Role.verifier,
      w: secret,
      proverId: initiatorId,
      verifierId: responderId,
    );
    return _Spake2Session(run);
  }
}

class _Spake2Session implements PakeSession {
  _Spake2Session(this._run);

  final Spake2 _run;

  @override
  List<int> get message => _run.outboundMessage;

  @override
  PakeResult finish(List<int> peerMessage) {
    final result = _run.finish(peerMessage);
    return PakeResult(
      sharedSecret: result.sharedSecret,
      localConfirmation: result.localConfirmation,
      expectedPeerConfirmation: result.expectedPeerConfirmation,
    );
  }
}
