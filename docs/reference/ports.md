# Ports

The engine depends on small interfaces ("ports"); the other packages provide
the production implementations ("adapters"). Everything here is on
`package:passnote/engine.dart`, the advanced library. Swap any of them through
the [builder](builder.md) or `passnoteLowLevel`.

## Transport

Discovers peers and moves opaque, already-encrypted frames.

```dart
abstract interface class Transport {
  Stream<PeerEvent> get events;     // PeerConnected / PeerLost
  Stream<InboundFrame> get inbound; // frames arriving from peers
  Future<void> start({required NodeId self, required String appId});
  Future<void> send(PeerId to, Frame frame);
  Future<void> stop();
}
```

Shipped: `LanTransport`, `WebSocketTransport` (see
[Transports](transports.md)), and the in-memory pair
`InMemoryBus`/`InMemoryTransport` for tests.

## CrdtTable

The record store beneath a collection: put, read, merge, watch, query, digest.
Implementations must satisfy `runCrdtTableConformance` (and
`runCrdtTypeConformance`), the behavioural contracts shipped in
`test_support/`. Shipped: `SqliteCrdtTable` (disk, the default; see
[SQLite schema](sqlite-schema.md)) and `MapCrdtTable` (in-memory, for tests).

Collections wrap any engine in `TypedCrdtTable`, the layer that gives `OrSet`
and `PnCounter` fields their merge rules; an engine only stores records and
merges last-write-wins.

## Cipher

Authenticated encryption, built per key.

```dart
abstract interface class Cipher {
  Future<List<int>> encrypt(List<int> plaintext);
  Future<List<int>> decrypt(List<int> ciphertext); // throws CipherAuthError
}
```

Shipped: `XChaChaPoly1305Cipher` (default) and `AesGcmCipher` in
`passnote_crypto`. Decrypt must fail closed on any tampered input.

## KeyStore

Persists derived keys and the device identity blob.

```dart
abstract interface class KeyStore {
  Future<List<int>?> getKey(String id);
  Future<void> setKey(String id, List<int> key);
  Future<void> clear(String id);
}
```

Shipped: `KeychainKeyStore` (OS keychain, in `passnote_flutter`).

## Identity

The device keypair: wrap and unwrap keys for peers, sign and verify roster
rows, fingerprint. `verify` checks any device's signature against its public
signing key; the device roster uses it to reject rows that are unsigned or
signed by a non-member. Shipped: `DeviceIdentity` (X25519 + Ed25519) in
`passnote_crypto`, including `DeviceIdentity.fromRecoveryPhrase` for the
recovery flow.

## Pake

The password-authenticated exchange behind pairing codes. Shipped:
`Spake2Pake` (SPAKE2 over P-256, RFC 9382) in `passnote_crypto`.

## MergeStrategy

How a document decomposes into records, and each field's `CrdtType`:

```dart
abstract interface class MergeStrategy {
  Iterable<FieldSpec> fields(Map<String, dynamic> document);
  Map<String, dynamic> unflatten(Iterable<FieldValue> rows);
  CrdtType typeAt(String path);
}
```

Shipped: `ObjectMergeStrategy`, `ShallowMergeStrategy`, `DeepMergeStrategy`,
`SchemaMergeStrategy`. See [Data model](../concepts/data-model.md).

## Codec

Your type to a stored map and back, plus the document id:

```dart
abstract interface class Codec<T> {
  Map<String, dynamic> toMap(T value);
  T fromMap(Map<String, dynamic> map);
  String idOf(T value);
}
```

Generate one with `@Document()` and `passnote_generator`, or hand-write a
`JsonCodec`.
