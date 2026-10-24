import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart'
    show KeyPairType, SimpleKeyPair, SimplePublicKey, X25519;
import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart' show RatchetSession, deriveRatchetRoot;
import 'package:passnote_crypto/passnote_crypto.dart';
import 'package:test/test.dart';

/// Asserts the known-answer vectors in `test/vectors/`. A failure here means
/// a primitive's output changed: either a regression, or a deliberate change
/// that must regenerate the vectors (`dart run tool/generate_vectors.dart`)
/// and be called out as breaking.
void main() {
  Map<String, dynamic> load(String name) =>
      jsonDecode(File('test/vectors/$name').readAsStringSync())
          as Map<String, dynamic>;

  String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  List<int> unhex(String s) => [
        for (var i = 0; i < s.length; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16),
      ];

  test('deriveKey and deriveRecoverySecret', () async {
    for (final c in load('derive_key.json')['cases'] as List) {
      final m = c as Map<String, dynamic>;
      expect(
        hex(await deriveKey(m['mnemonic'] as String, m['salt'] as String)),
        m['key'],
        reason: m['name'] as String,
      );
      if (m['recovery_secret'] case final String secret) {
        expect(
          hex(await deriveRecoverySecret(
              m['mnemonic'] as String, m['salt'] as String)),
          secret,
          reason: m['name'] as String,
        );
      }
      expect(
        hex(await deriveKeyLegacy(
            m['mnemonic'] as String, m['salt'] as String)),
        m['legacy_key'] ?? m['key'],
        reason: '${m['name']} (legacy)',
      );
    }
  });

  test('bip39Seed matches BIP39', () async {
    for (final c in load('derive_key.json')['seeds'] as List) {
      final m = c as Map<String, dynamic>;
      expect(hex(await bip39Seed(m['phrase'] as String)), m['seed'],
          reason: m['phrase'] as String);
    }
  });

  test('the legacy derivation collides distinct characters', () async {
    // U+0141 and U+0041 share their low byte.
    expect(await deriveKeyLegacy('Ł', 's'), await deriveKeyLegacy('A', 's'));
    expect(await deriveKey('Ł', 's'), isNot(await deriveKey('A', 's')));
  });

  test('roomTag', () {
    for (final c in load('room_tag.json')['cases'] as List) {
      final m = c as Map<String, dynamic>;
      expect(roomTag(unhex(m['key'] as String)), m['tag']);
    }
  });

  test('XChaCha20-Poly1305 frames', () async {
    for (final c in load('xchacha.json')['cases'] as List) {
      final m = c as Map<String, dynamic>;
      final cipher = XChaChaPoly1305Cipher(unhex(m['key'] as String));
      final frame = await cipher.encryptWithNonce(
        unhex(m['plaintext'] as String),
        unhex(m['nonce'] as String),
      );
      expect(hex(frame), m['frame']);
      // And the frame opens.
      expect(hex(await cipher.decrypt(frame)), m['plaintext']);
    }
  });

  test('SPAKE2 fixed transcript', () {
    final c = load('spake2.json')['case'] as Map<String, dynamic>;
    final prover = Spake2.start(
      role: Spake2Role.prover,
      w: unhex(c['w'] as String),
      proverId: utf8.encode(c['prover_id'] as String),
      verifierId: utf8.encode(c['verifier_id'] as String),
      scalarOverride: BigInt.parse('0x${c['prover_scalar']}'),
    );
    final verifier = Spake2.start(
      role: Spake2Role.verifier,
      w: unhex(c['w'] as String),
      proverId: utf8.encode(c['prover_id'] as String),
      verifierId: utf8.encode(c['verifier_id'] as String),
      scalarOverride: BigInt.parse('0x${c['verifier_scalar']}'),
    );
    expect(hex(prover.outboundMessage), c['pA']);
    expect(hex(verifier.outboundMessage), c['pB']);
    final result = prover.finish(verifier.outboundMessage);
    expect(hex(result.sharedSecret), c['shared_secret']);
    expect(hex(result.localConfirmation), c['cA']);
    expect(hex(verifier.finish(prover.outboundMessage).localConfirmation),
        c['cB']);
    expect(hex(result.transcript), c['transcript']);
  });

  test('key wrap with a fixed ephemeral', () async {
    final c = load('key_wrap.json')['case'] as Map<String, dynamic>;
    final recipient = await DeviceIdentity.fromRecoveryPhrase(
      c['recipient_phrase'] as String,
      salt: c['recipient_salt'] as String,
    );
    expect(hex((await recipient.publicKey).keyExchange), c['recipient_kx_pub']);
    final wrapped = await recipient.wrapForWithEphemeralSeed(
      await recipient.publicKey,
      unhex(c['wrapped_key'] as String),
      unhex(c['ephemeral_seed'] as String),
      gcmNonce: unhex(c['gcm_nonce'] as String),
    );
    expect(hex(wrapped.toBytes()), c['wrapped']);
    // And the wrap opens.
    expect(hex(await recipient.unwrap(wrapped)), c['wrapped_key']);
  });

  test('a 1.0 key wrap still opens', () async {
    // Frozen: the pre-1.1.0 derivation, bound to the recipient key only.
    final c = load('key_wrap_v1.json')['case'] as Map<String, dynamic>;
    final recipient = await DeviceIdentity.fromRecoveryPhrase(
      c['recipient_phrase'] as String,
      salt: c['recipient_salt'] as String,
    );
    final wrapped = WrappedKey.fromBytes(unhex(c['wrapped'] as String));
    expect(hex(await recipient.unwrap(wrapped)), c['wrapped_key']);
  });

  test('ratchet root and message-key chain', () async {
    final c = load('ratchet.json')['case'] as Map<String, dynamic>;
    final x25519 = X25519();
    final ephA =
        await x25519.newKeyPairFromSeed(unhex(c['ephemeral_seed_a'] as String));
    final ephB =
        await x25519.newKeyPairFromSeed(unhex(c['ephemeral_seed_b'] as String));
    final pubA = (await ephA.extractPublicKey()).bytes;
    final pubB = (await ephB.extractPublicKey()).bytes;
    expect(hex(pubA), c['ephemeral_pub_a']);
    expect(hex(pubB), c['ephemeral_pub_b']);
    Future<List<int>> agree(SimpleKeyPair mine, List<int> theirs) async =>
        (await x25519.sharedSecretKey(
          keyPair: mine,
          remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
        ))
            .extractBytes();
    final shared = await agree(ephA, pubB);
    expect(hex(shared), c['shared_secret']);
    expect(hex(await agree(ephB, pubA)), c['shared_secret']);
    final root = deriveRatchetRoot(
      groupKey: unhex(c['group_key'] as String),
      sharedSecret: shared,
      ephemeralA: pubA,
      ephemeralB: pubB,
      nodeA: c['node_a'] as String,
      nodeB: c['node_b'] as String,
    );
    expect(hex(root), c['root']);

    final captured = <String>[];
    final low = RatchetSession.establish(
      root: root,
      thisNodeIsLow: true,
      cipherFactory: (key) {
        captured.add(hex(key));
        return _NullCipher();
      },
    );
    final expected = (c['low_side_send_keys'] as List).cast<String>();
    for (var i = 0; i < expected.length; i++) {
      await low.seal([i]);
    }
    expect(captured, expected);
  });
}

class _NullCipher implements Cipher {
  @override
  Future<List<int>> encrypt(List<int> plaintext) async => plaintext;
  @override
  Future<List<int>> decrypt(List<int> ciphertext) async => ciphertext;
}
