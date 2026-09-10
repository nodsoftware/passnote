import 'dart:typed_data';

import 'package:conclave/conclave.dart';
import 'package:conclave_crypto/conclave_crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

/// In-memory [KeyStore] that also counts writes, so a test can assert a key was
/// generated exactly once.
class _FakeKeyStore implements KeyStore {
  final Map<String, List<int>> _entries = {};
  int writes = 0;

  @override
  Future<List<int>?> getKey(String id) async => _entries[id];

  @override
  Future<void> setKey(String id, List<int> key) async {
    writes++;
    _entries[id] = key;
  }

  @override
  Future<void> clear(String id) async => _entries.remove(id);
}

void main() {
  test('load generates a keypair once and reuses it across restarts', () async {
    final store = _FakeKeyStore();

    final first = await DeviceIdentity.load(keyStore: store);
    expect(store.writes, 1);

    final second = await DeviceIdentity.load(keyStore: store);
    expect(store.writes, 1, reason: 'the second load must not regenerate');

    expect(second.deviceId, first.deviceId);
    expect(
      (await second.publicKey).toBytes(),
      (await first.publicKey).toBytes(),
    );

    // A third, entirely fresh instance over the same store — simulating a
    // process restart — still lands on the same identity.
    final restarted = await DeviceIdentity.load(keyStore: _copy(store));
    expect(restarted.deviceId, first.deviceId);
  });

  test('wrapFor / unwrap round-trips a 32-byte key between two identities',
      () async {
    final alice = await DeviceIdentity.generate();
    final bob = await DeviceIdentity.generate();
    final key = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

    final wrapped = await alice.wrapFor(await bob.publicKey, key);
    expect(await bob.unwrap(wrapped), key);

    // The wire encoding round-trips too.
    final decoded = WrappedKey.fromBytes(wrapped.toBytes());
    expect(await bob.unwrap(decoded), key);
  });

  test('a wrap sealed to one device cannot be opened by another', () async {
    final alice = await DeviceIdentity.generate();
    final bob = await DeviceIdentity.generate();
    final mallory = await DeviceIdentity.generate();
    final key = Uint8List.fromList(List.filled(32, 9));

    final wrapped = await alice.wrapFor(await bob.publicKey, key);
    await expectLater(mallory.unwrap(wrapped), throwsStateError);
  });

  test('sign output verifies against publicKey.signing', () async {
    final identity = await DeviceIdentity.generate();
    final message = Uint8List.fromList('conclave pairing token'.codeUnits);

    final signature = await identity.sign(message);
    final pub = await identity.publicKey;

    final ok = await Ed25519().verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(pub.signing, type: KeyPairType.ed25519),
      ),
    );
    expect(ok, isTrue);

    final tampered = Uint8List.fromList(message)..[0] ^= 0x01;
    final bad = await Ed25519().verify(
      tampered,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(pub.signing, type: KeyPairType.ed25519),
      ),
    );
    expect(bad, isFalse);
  });

  test('deviceId is stable per keypair and unique across keypairs', () async {
    final a = await DeviceIdentity.generate();
    final b = await DeviceIdentity.generate();

    expect(a.deviceId, matches(RegExp(r'^[A-Z2-7]{16}$')));
    expect(a.deviceId, isNot(b.deviceId));

    // Reloading the same stored blob yields the same id.
    final store = _FakeKeyStore();
    final loaded = await DeviceIdentity.load(keyStore: store);
    final reloaded = await DeviceIdentity.load(keyStore: store);
    expect(reloaded.deviceId, loaded.deviceId);
  });

  group('recovery identity', () {
    test('the same phrase and salt always derive the same identity', () async {
      final phrase = generateMnemonic(words: 24).join(' ');
      final first =
          await DeviceIdentity.fromRecoveryPhrase(phrase, salt: 'app:v1');
      final again =
          await DeviceIdentity.fromRecoveryPhrase(phrase, salt: 'app:v1');
      expect(again.deviceId, first.deviceId);
      expect(
          (await again.publicKey).toBytes(), (await first.publicKey).toBytes());
    });

    test('a different phrase or salt derives a different identity', () async {
      final phrase = generateMnemonic(words: 24).join(' ');
      final other = generateMnemonic(words: 24).join(' ');
      final base =
          await DeviceIdentity.fromRecoveryPhrase(phrase, salt: 'app:v1');
      expect(
        (await DeviceIdentity.fromRecoveryPhrase(other, salt: 'app:v1'))
            .deviceId,
        isNot(base.deviceId),
      );
      expect(
        (await DeviceIdentity.fromRecoveryPhrase(phrase, salt: 'other:v1'))
            .deviceId,
        isNot(base.deviceId),
      );
    });

    test('a wrap sealed to the phrase opens on a fresh derivation', () async {
      // The recovery scenario: the device that sealed the wrap is gone; only
      // the phrase survives, and a fresh install re-derives the keypair.
      final phrase = generateMnemonic(words: 24).join(' ');
      final registered =
          await DeviceIdentity.fromRecoveryPhrase(phrase, salt: 'app:v1');
      final sponsor = await DeviceIdentity.generate();
      final groupKey = List<int>.generate(32, (i) => i * 3 & 0xff);

      final wrap = await sponsor.wrapFor(await registered.publicKey, groupKey);

      final freshInstall =
          await DeviceIdentity.fromRecoveryPhrase(phrase, salt: 'app:v1');
      expect(await freshInstall.unwrap(wrap), groupKey);
    });
  });
}

_FakeKeyStore _copy(_FakeKeyStore other) {
  final copy = _FakeKeyStore();
  other._entries.forEach((key, value) => copy._entries[key] = value);
  return copy;
}
