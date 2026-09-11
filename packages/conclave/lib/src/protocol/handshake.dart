/// Wire-version negotiation for the connection handshake.
///
/// On connect, both sides of a database room exchange a `HandshakeMessage`
/// carrying the wire versions they speak (and their device public key). The
/// pure [negotiate] picks the version both understand; no overlap surfaces a
/// `PeerIncompatible` event instead of a silent never-syncs.
library;

/// The wire versions this build can speak; [negotiate] picks the highest one
/// both sides share.
const List<int> supportedWireVersions = [1];

/// The highest wire version present in both [local] and [remote], or `null`
/// when the sets share none (the peers cannot talk).
int? negotiate(List<int> local, List<int> remote) {
  int? best;
  for (final version in local) {
    if (!remote.contains(version)) continue;
    if (best == null || version > best) best = version;
  }
  return best;
}
