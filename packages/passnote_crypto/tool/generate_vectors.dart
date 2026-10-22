// Regenerates the known-answer vectors in test/vectors/ from the current
// implementation. Run only when a primitive deliberately changes; the diff is
// the review artefact:
//
//   dart run tool/generate_vectors.dart
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart'
    show KeyPairType, SimplePublicKey, X25519;
import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart' show RatchetSession, deriveRatchetRoot;
import 'package:passnote_crypto/passnote_crypto.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> bytesOf(int length, int seed) =>
    List<int>.generate(length, (i) => (seed + i * 7) & 0xff);

const mnemonic12 =
    'legal winner thank year wave sausage worth useful legal winner thank yellow';
const mnemonic24 =
    'letter advice cage absurd amount doctor acoustic avoid letter advice '
    'cage absurd amount doctor acoustic avoid letter advice cage absurd '
    'amount doctor acoustic bless';

Future<void> main() async {
  final out = Directory('test/vectors');

  // 1. deriveKey (Argon2id) and deriveRecoverySecret.
  final deriveCases = <Map<String, Object>>[];
  for (final (name, phrase, salt) in [
    ('12-word mnemonic', mnemonic12, 'vectors:v1'),
    ('24-word mnemonic', mnemonic24, 'vectors:v1'),
    ('same phrase, other salt', mnemonic12, 'other-app:v1'),
  ]) {
    deriveCases.add({
      'name': name,
      'mnemonic': phrase,
      'salt': salt,
      'key': hex(await deriveKey(phrase, salt)),
      'recovery_secret': hex(await deriveRecoverySecret(phrase, salt)),
    });
  }
  _write(out, 'derive_key.json', {
    'primitive': 'BIP39 seed -> Argon2id(memory=19456 KiB, iterations=2, lanes=1, '
        'hashLength=32); argon salt = SHA-256("passnote-kdf-salt/<salt>")[0..16]; '
        'recovery variant uses salt "recovery-v1/<salt>"',
    'cases': deriveCases,
  });

  // 2. roomTag.
  _write(out, 'room_tag.json', {
    'primitive':
        'base32(SHA-256(key || "passnote-room"))[0..16], RFC 4648 alphabet, '
            'no padding',
    'cases': [
      for (final seed in [0, 1, 0x42])
        {
          'key': hex(bytesOf(32, seed)),
          'tag': roomTag(bytesOf(32, seed)),
        },
    ],
  });

  // 3. XChaCha20-Poly1305 frames.
  final xchachaCases = <Map<String, Object>>[];
  for (final (keySeed, nonceSeed, plaintext) in [
    (1, 2, <int>[]),
    (1, 2, [0x68, 0x69]), // "hi"
    (9, 5, bytesOf(64, 3)),
  ]) {
    final cipher = XChaChaPoly1305Cipher(bytesOf(32, keySeed));
    // This generator is the producer of the published test vectors, the one
    // job the test-only nonce seam exists for.
    final frame =
        // ignore: invalid_use_of_visible_for_testing_member
        await cipher.encryptWithNonce(plaintext, bytesOf(24, nonceSeed));
    xchachaCases.add({
      'key': hex(bytesOf(32, keySeed)),
      'nonce': hex(bytesOf(24, nonceSeed)),
      'plaintext': hex(plaintext),
      'frame': hex(frame),
    });
  }
  _write(out, 'xchacha.json', {
    'primitive':
        'XChaCha20-Poly1305; frame = nonce(24) || ciphertext || tag(16)',
    'cases': xchachaCases,
  });

  // 4. SPAKE2 (P-256, RFC 9382) fixed transcript.
  final prover = Spake2.start(
    role: Spake2Role.prover,
    w: bytesOf(32, 0x11),
    proverId: utf8.encode('client'),
    verifierId: utf8.encode('server'),
    scalarOverride: BigInt.parse('0x${hex(bytesOf(32, 0x21))}'),
  );
  final verifier = Spake2.start(
    role: Spake2Role.verifier,
    w: bytesOf(32, 0x11),
    proverId: utf8.encode('client'),
    verifierId: utf8.encode('server'),
    scalarOverride: BigInt.parse('0x${hex(bytesOf(32, 0x31))}'),
  );
  final proverResult = prover.finish(verifier.outboundMessage);
  final verifierResult = verifier.finish(prover.outboundMessage);
  _write(out, 'spake2.json', {
    'primitive': 'SPAKE2 over P-256 (RFC 9382); identities in the transcript; '
        'Ke = TT-hash[0..16]',
    'case': {
      'w': hex(bytesOf(32, 0x11)),
      'prover_scalar': hex(bytesOf(32, 0x21)),
      'verifier_scalar': hex(bytesOf(32, 0x31)),
      'prover_id': 'client',
      'verifier_id': 'server',
      'pA': hex(prover.outboundMessage),
      'pB': hex(verifier.outboundMessage),
      'shared_secret': hex(proverResult.sharedSecret),
      'cA': hex(proverResult.localConfirmation),
      'cB': hex(verifierResult.localConfirmation),
      'transcript': hex(proverResult.transcript),
    },
  });

  // 5. Key wrap with a fixed ephemeral and GCM nonce. The recipient identity
  // derives from a recovery phrase so the whole case is reproducible.
  final recipient =
      await DeviceIdentity.fromRecoveryPhrase(mnemonic24, salt: 'vectors:v1');
  // Same justification as encryptWithNonce above: vectors need fixed inputs.
  // ignore: invalid_use_of_visible_for_testing_member
  final wrapped = await recipient.wrapForWithEphemeralSeed(
    await recipient.publicKey,
    bytesOf(32, 0x55),
    bytesOf(32, 0x66),
    gcmNonce: bytesOf(12, 0x77),
  );
  _write(out, 'key_wrap.json', {
    'primitive':
        'X25519(ephemeral, recipient) -> HKDF-SHA256(info="passnote-key-wrap-v1" '
            '|| recipientPub) -> AES-256-GCM; encoding ephemeralPub(32) || '
            'nonce(12) || ct || tag(16)',
    'case': {
      'recipient_phrase': mnemonic24,
      'recipient_salt': 'vectors:v1',
      'recipient_kx_pub': hex((await recipient.publicKey).keyExchange),
      'wrapped_key': hex(bytesOf(32, 0x55)),
      'ephemeral_seed': hex(bytesOf(32, 0x66)),
      'gcm_nonce': hex(bytesOf(12, 0x77)),
      'wrapped': hex(wrapped.toBytes()),
    },
  });

  // 6. Ratchet: the ephemeral agreement, the root, and the first message keys
  // per direction, captured through the cipher factory (the keys ARE the
  // cipher inputs).
  final x25519 = X25519();
  final ephA = await x25519.newKeyPairFromSeed(bytesOf(32, 0x04));
  final ephB = await x25519.newKeyPairFromSeed(bytesOf(32, 0x05));
  final pubA = (await ephA.extractPublicKey()).bytes;
  final pubB = (await ephB.extractPublicKey()).bytes;
  final shared = await (await x25519.sharedSecretKey(
    keyPair: ephA,
    remotePublicKey: SimplePublicKey(pubB, type: KeyPairType.x25519),
  ))
      .extractBytes();
  final root = deriveRatchetRoot(
    groupKey: bytesOf(32, 0x01),
    sharedSecret: shared,
    ephemeralA: pubA,
    ephemeralB: pubB,
    nodeA: 'node-a',
    nodeB: 'node-b',
  );
  final sendKeys = <String>[];
  final low = RatchetSession.establish(
    root: root,
    thisNodeIsLow: true,
    cipherFactory: (key) {
      sendKeys.add(hex(key));
      return _NullCipher();
    },
  );
  for (var i = 0; i < 4; i++) {
    await low.seal([i]);
  }
  _write(out, 'ratchet.json', {
    'primitive':
        'shared = X25519(ephemeral A, ephemeral B); root = HKDF-SHA256(ikm = '
            'groupKey || shared, info = "passnote-ratchet-root-v2" || sorted '
            'node ids || sorted ephemeral public keys); per-frame message keys '
            'from an HMAC-SHA256 hash chain, one per seal, previous key wiped',
    'case': {
      'group_key': hex(bytesOf(32, 0x01)),
      'ephemeral_seed_a': hex(bytesOf(32, 0x04)),
      'ephemeral_seed_b': hex(bytesOf(32, 0x05)),
      'ephemeral_pub_a': hex(pubA),
      'ephemeral_pub_b': hex(pubB),
      'shared_secret': hex(shared),
      'node_a': 'node-a',
      'node_b': 'node-b',
      'root': hex(root),
      'low_side_send_keys': sendKeys,
    },
  });

  stdout.writeln('vectors written to ${out.path}/');
}

void _write(Directory dir, String name, Map<String, Object> content) {
  File('${dir.path}/$name').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(content)}\n',
  );
}

class _NullCipher implements Cipher {
  @override
  Future<List<int>> encrypt(List<int> plaintext) async => plaintext;
  @override
  Future<List<int>> decrypt(List<int> ciphertext) async => ciphertext;
}
