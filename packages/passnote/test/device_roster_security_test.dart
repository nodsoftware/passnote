// The revocation threat model: a revoked device keeps the roster key (it is
// passphrase-derived and never rotates), so it can still WRITE rows into the
// roster collection. These tests prove that such rows are ignored: roster rows
// are signed, and rotation seals the new group key only to devices whose
// records chain back to the founder through non-revoked signers.
import 'dart:convert';

import 'package:crdt/crdt.dart' show Hlc;

import 'package:passnote/passnote.dart';
// The roster orchestrator is deliberately not exported; test it directly.
import 'package:passnote/src/collection.dart' as internal;
import 'package:passnote/src/identity/device_roster.dart' as internal;
import 'package:test/test.dart';

/// An [Identity] fake with real signature semantics: each identity holds a
/// private secret, `sign` MACs the message with it, and `verify` recomputes
/// through a registry keyed by the signing public key. A signature therefore
/// only verifies for the identity that actually produced it.
class _SigningIdentity implements Identity {
  _SigningIdentity(int seed)
      : _secret = List<int>.generate(32, (i) => (seed * 131 + i * 17) & 0xff),
        _pub = DevicePublicKey(
          keyExchange:
              List<int>.generate(32, (i) => (seed * 31 + i * 7) & 0xff),
          signing: List<int>.generate(32, (i) => (seed * 13 + i * 5) & 0xff),
        ) {
    _registry[base64.encode(_pub.signing)] = _secret;
  }

  static final Map<String, List<int>> _registry = {};

  final List<int> _secret;
  final DevicePublicKey _pub;

  @override
  Future<DevicePublicKey> get publicKey async => _pub;

  @override
  String get deviceId => fingerprintOf(_pub);

  @override
  String fingerprintOf(DevicePublicKey publicKey) {
    var acc = 0;
    for (final b in publicKey.keyExchange) {
      acc = (acc * 31 + b) & 0x7fffffff;
    }
    return 'D${acc.toRadixString(16).padLeft(15, '0')}'.substring(0, 16);
  }

  static List<int> _mac(List<int> secret, List<int> message) {
    var h = 0x811c9dc5;
    final out = List<int>.filled(32, 0);
    for (var round = 0; round < 32; round++) {
      for (final b in [...secret, round, ...message]) {
        h = ((h ^ b) * 0x01000193) & 0xffffffff;
      }
      out[round] = h & 0xff;
    }
    return out;
  }

  @override
  Future<List<int>> sign(List<int> message) async => _mac(_secret, message);

  @override
  Future<bool> verify(
    List<int> message, {
    required List<int> signature,
    required DevicePublicKey signer,
  }) async {
    final secret = _registry[base64.encode(signer.signing)];
    if (secret == null) return false;
    final expected = _mac(secret, message);
    if (expected.length != signature.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ signature[i];
    }
    return diff == 0;
  }

  @override
  Future<WrappedKey> wrapFor(DevicePublicKey peer, List<int> key) async {
    final ks = _ks(peer.keyExchange, key.length);
    return WrappedKey(
      ephemeralPublicKey: List<int>.of(peer.keyExchange),
      nonce: List<int>.filled(12, 0),
      ciphertext: [
        for (var i = 0; i < key.length; i++) key[i] ^ ks[i],
        ...List<int>.filled(16, 0xAA),
      ],
    );
  }

  @override
  Future<List<int>> unwrap(WrappedKey wrapped) async {
    if (!_eq(wrapped.ephemeralPublicKey, _pub.keyExchange)) {
      throw StateError('not sealed to this device');
    }
    final body = wrapped.ciphertext.sublist(0, wrapped.ciphertext.length - 16);
    final ks = _ks(_pub.keyExchange, body.length);
    return [for (var i = 0; i < body.length; i++) body[i] ^ ks[i]];
  }

  static List<int> _ks(List<int> seed, int n) =>
      List<int>.generate(n, (i) => seed[i % seed.length] ^ (i & 0xff));
  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Rebuilds the canonical signed payload of a [DeviceRecord], mirroring
/// DeviceRoster's format — this is what a forger armed with the roster key
/// and the row schema would compute.
List<int> recordPayload(DeviceRecord r) => utf8.encode([
      'passnote-roster-device-v1',
      r.deviceId,
      base64.encode(r.publicKey),
      r.label,
      r.pairedAt.toUtc().toIso8601String(),
      r.revoked.toString(),
      r.signedBy,
    ].join('\x1F'));

/// Same for a [WrappedGroupKey].
List<int> wrapPayload(WrappedGroupKey w) => utf8.encode([
      'passnote-roster-wrap-v1',
      w.deviceId,
      w.keyEpoch.toString(),
      base64.encode(w.wrappedBytes),
      w.signedBy,
    ].join('\x1F'));

void main() {
  late internal.Collection<DeviceRosterEntry> roster;
  late _SigningIdentity idA; // founder
  late _SigningIdentity idB; // attacker: legitimately paired, then revoked
  late _SigningIdentity idC; // an honest second device
  late _SigningIdentity idE; // the attacker's fresh identity
  late internal.DeviceRoster rosterA;
  late internal.DeviceRoster rosterB;

  setUp(() async {
    roster = internal.Collection.create<DeviceRosterEntry>(
      internal.kDeviceCollection,
      internal.deviceRosterCodec,
    );
    idA = _SigningIdentity(1);
    idB = _SigningIdentity(2);
    idC = _SigningIdentity(3);
    idE = _SigningIdentity(4);
    rosterA = internal.DeviceRoster(roster, idA);
    rosterB = internal.DeviceRoster(roster, idB);

    await rosterA.found(label: 'A');
    await rosterA.admit(await idB.publicKey, label: 'B');
    await rosterA.admit(await idC.publicKey, label: 'C');
    await rosterB.resolve();
    expect(rosterB.state, DeviceState.ready);
    await rosterA.revoke(idB.deviceId);
  });

  test('a revoked device cannot smuggle a fresh identity into the roster',
      () async {
    // The attack from the review: B (revoked, still holding the roster key)
    // writes a DeviceRecord for a fresh identity E it controls, correctly
    // signed with its own key, then waits for the next rotation.
    final forged = DeviceRecord(
      deviceId: idE.deviceId,
      publicKey: (await idE.publicKey).toBytes(),
      label: 'innocent looking phone',
      pairedAt: DateTime.now().toUtc(),
      signedBy: idB.deviceId,
    );
    await roster.put(DeviceRecord(
      deviceId: forged.deviceId,
      publicKey: forged.publicKey,
      label: forged.label,
      pairedAt: forged.pairedAt,
      signedBy: forged.signedBy,
      signature: await idB.sign(recordPayload(forged)),
    ));

    // E never shows up in the validated roster.
    expect((await rosterA.devices()).map((d) => d.id),
        isNot(contains(idE.deviceId)));

    // A rotation (here: revoking C) seals the new key to no forged record.
    await rosterA.revoke(idC.deviceId);
    final rows = await roster.all();
    final wrapsForE = rows
        .whereType<WrappedGroupKey>()
        .where((w) => w.deviceId == idE.deviceId);
    expect(wrapsForE, isEmpty,
        reason: 'the rotator must never wrap the group key to a record whose '
            'signer is revoked');

    // And E cannot resolve to ready.
    final rosterE = internal.DeviceRoster(roster, idE);
    expect(await rosterE.resolve(), DeviceState.needsPairing);
  });

  test('an unsigned device record is ignored', () async {
    await roster.put(DeviceRecord(
      deviceId: idE.deviceId,
      publicKey: (await idE.publicKey).toBytes(),
      label: 'unsigned',
      pairedAt: DateTime.now().toUtc(),
    ));
    expect((await rosterA.devices()).map((d) => d.id),
        isNot(contains(idE.deviceId)));
  });

  test('a record claiming a trusted signer with a forged signature is ignored',
      () async {
    // B forges a record that CLAIMS to be signed by A but is signed by B.
    final forged = DeviceRecord(
      deviceId: idE.deviceId,
      publicKey: (await idE.publicKey).toBytes(),
      label: 'forged claim',
      pairedAt: DateTime.now().toUtc(),
      signedBy: idA.deviceId,
    );
    await roster.put(DeviceRecord(
      deviceId: forged.deviceId,
      publicKey: forged.publicKey,
      label: forged.label,
      pairedAt: forged.pairedAt,
      signedBy: forged.signedBy,
      signature: await idB.sign(recordPayload(forged)),
    ));
    expect((await rosterA.devices()).map((d) => d.id),
        isNot(contains(idE.deviceId)));
  });

  test('a revoked device cannot trigger a rotation with an injected wrap',
      () async {
    final epochBefore = rosterA.keyEpoch;
    // B writes a wrap row at the live epoch for its own (revoked) id, the
    // trigger that would make the elected rotator rotate and — before rows
    // were signed — seal the new key to every record in the roster.
    final fake = WrappedGroupKey(
      deviceId: idB.deviceId,
      keyEpoch: epochBefore,
      wrappedBytes: List<int>.filled(64, 1),
      signedBy: idB.deviceId,
    );
    await roster.put(WrappedGroupKey(
      deviceId: fake.deviceId,
      keyEpoch: fake.keyEpoch,
      wrappedBytes: fake.wrappedBytes,
      signedBy: fake.signedBy,
      signature: await idB.sign(wrapPayload(fake)),
    ));

    await rosterA.reconcile();
    expect(rosterA.keyEpoch, epochBefore,
        reason: 'a wrap signed by a revoked device is not a leak signal');
  });

  test('an injected wrap cannot make a device adopt an attacker-known key',
      () async {
    final keyBefore = rosterA.groupKey;
    // B seals a key it knows to A at a far-future epoch.
    final attackerKey = List<int>.filled(32, 0x42);
    final wrapped = await idB.wrapFor(await idA.publicKey, attackerKey);
    final fake = WrappedGroupKey(
      deviceId: idA.deviceId,
      keyEpoch: 99,
      wrappedBytes: wrapped.toBytes(),
      signedBy: idB.deviceId,
    );
    await roster.put(WrappedGroupKey(
      deviceId: fake.deviceId,
      keyEpoch: fake.keyEpoch,
      wrappedBytes: fake.wrappedBytes,
      signedBy: fake.signedBy,
      signature: await idB.sign(wrapPayload(fake)),
    ));

    await rosterA.resolve();
    expect(rosterA.state, DeviceState.ready);
    expect(rosterA.groupKey, keyBefore,
        reason: 'a wrap signed by a revoked device must never be unwrapped');
    expect(rosterA.keyEpoch, isNot(99));
  });

  test('the revoked device still resolves as revoked, honest devices as ready',
      () async {
    expect(await rosterB.resolve(), DeviceState.revoked);
    final rosterC = internal.DeviceRoster(roster, idC);
    expect(await rosterC.resolve(), DeviceState.ready);
    expect(await rosterA.resolve(), DeviceState.ready);
  });

  group('merge-time vetting (vetInbound)', () {
    /// A wire-shaped changeset for [rows]: one existence register and one
    /// whole-document value record per row, as the roster's merge strategy
    /// stores them.
    Map<String, List<Map<String, Object?>>> changesetOf(
      List<DeviceRosterEntry> rows, {
      bool deleted = false,
    }) =>
        {
          internal.kDeviceCollection: [
            for (final e in rows) ...[
              {'key': e.documentId, 'value': true, 'is_deleted': deleted},
              {
                'key': '${e.documentId}\x1F',
                'value': internal.deviceRosterCodec.toMap(e),
                'is_deleted': deleted,
              },
            ],
          ],
        };

    Future<DeviceRecord> signedRecord(
      _SigningIdentity subject,
      _SigningIdentity signer, {
      String label = 'device',
    }) async {
      final unsigned = DeviceRecord(
        deviceId: subject.deviceId,
        publicKey: (await subject.publicKey).toBytes(),
        label: label,
        pairedAt: DateTime.now().toUtc(),
        signedBy: signer.deviceId,
      );
      return DeviceRecord(
        deviceId: unsigned.deviceId,
        publicKey: unsigned.publicKey,
        label: unsigned.label,
        pairedAt: unsigned.pairedAt,
        signedBy: unsigned.signedBy,
        signature: await signer.sign(recordPayload(unsigned)),
      );
    }

    test('rows written by a revoked device are dropped before merge', () async {
      final junk = [
        for (var i = 0; i < 20; i++)
          await signedRecord(_SigningIdentity(100 + i), idB, label: 'junk $i'),
      ];
      final vetted = await rosterA.vetInbound(changesetOf(junk));
      expect(vetted[internal.kDeviceCollection], isEmpty,
          reason: 'nothing a revoked device writes is worth persisting');
    });

    test('rows from an unknown signer are dropped before merge', () async {
      final stranger = _SigningIdentity(200);
      final row = await signedRecord(_SigningIdentity(201), stranger);
      final vetted = await rosterA.vetInbound(changesetOf([row]));
      expect(vetted[internal.kDeviceCollection], isEmpty);
    });

    test('a tombstone for a roster row is refused', () async {
      final record = await signedRecord(idC, idA);
      final vetted =
          await rosterA.vetInbound(changesetOf([record], deleted: true));
      expect(vetted[internal.kDeviceCollection], isEmpty,
          reason: 'no roster row is ever legitimately deleted');
    });

    test('a member admission and rows the new device signed share a frame',
        () async {
      final idF = _SigningIdentity(6);
      final idG = _SigningIdentity(7);
      // A admits F; F (now a member) admits G — all in one changeset, with
      // F's row deliberately ordered after G's.
      final rows = [
        await signedRecord(idG, idF, label: 'G'),
        await signedRecord(idF, idA, label: 'F'),
      ];
      final vetted = await rosterA.vetInbound(changesetOf(rows));
      expect(vetted[internal.kDeviceCollection], hasLength(4),
          reason: 'both documents (existence + value records) are admitted');
    });

    test('a device that has never seen a roster admits its first sync whole',
        () async {
      final fresh = internal.Collection.create<DeviceRosterEntry>(
        internal.kDeviceCollection,
        internal.deviceRosterCodec,
      );
      final newcomer = internal.DeviceRoster(fresh, _SigningIdentity(300));
      final rows = [await signedRecord(idC, idA)];
      final vetted = await newcomer.vetInbound(changesetOf(rows));
      expect(vetted[internal.kDeviceCollection], hasLength(2),
          reason: 'before a founder is pinned, sync is trust-on-first-use');
    });

    test('valid member writes pass the vet', () async {
      final rename = await signedRecord(idC, idA, label: 'C renamed');
      final vetted = await rosterA.vetInbound(changesetOf([rename]));
      expect(vetted[internal.kDeviceCollection], hasLength(2));
    });
  });

  group('validation order and identity binding', () {
    test(
        'a fresh device judges a revocation before the revoked device\'s '
        'later introductions', () async {
      // The revoker is not the founder, so a naive pass meets the revoked
      // device's forged introduction before it has learned who the revoker
      // is. Revocation must win regardless of the order rows come back in.
      final store = internal.Collection.create<DeviceRosterEntry>(
        internal.kDeviceCollection,
        internal.deviceRosterCodec,
      );
      final founder = _SigningIdentity(11);
      final revoker = _SigningIdentity(12);
      final revoked = _SigningIdentity(13);
      final puppet = _SigningIdentity(14);
      final fresh = _SigningIdentity(15);
      final rosterFounder = internal.DeviceRoster(store, founder);
      await rosterFounder.found(label: 'founder');
      await rosterFounder.admit(await revoker.publicKey, label: 'revoker');
      await rosterFounder.admit(await revoked.publicKey, label: 'revoked');
      final rosterRevoker = internal.DeviceRoster(store, revoker);
      expect(await rosterRevoker.resolve(), DeviceState.ready);
      await rosterRevoker.revoke(revoked.deviceId);

      // After its revocation, the revoked device vouches for a puppet.
      final forged = DeviceRecord(
        deviceId: puppet.deviceId,
        publicKey: (await puppet.publicKey).toBytes(),
        label: 'puppet',
        pairedAt: DateTime.now().toUtc(),
        signedBy: revoked.deviceId,
      );
      await store.put(DeviceRecord(
        deviceId: forged.deviceId,
        publicKey: forged.publicKey,
        label: forged.label,
        pairedAt: forged.pairedAt,
        signedBy: forged.signedBy,
        signature: await revoked.sign(recordPayload(forged)),
      ));

      // A device seeing this roster for the first time, with no pins.
      final rosterFresh = internal.DeviceRoster(store, fresh);
      final ids = {for (final d in await rosterFresh.devices()) d.id};
      expect(ids, isNot(contains(puppet.deviceId)));
      expect(
        (await rosterFresh.devices())
            .firstWhere((d) => d.id == revoked.deviceId)
            .revoked,
        isTrue,
      );
    });

    test(
        'a device introduced by a since-revoked member keeps its standing, '
        'because the revoker re-signs it', () async {
      final store = internal.Collection.create<DeviceRosterEntry>(
        internal.kDeviceCollection,
        internal.deviceRosterCodec,
      );
      final founder = _SigningIdentity(21);
      final sponsor = _SigningIdentity(22);
      final introduced = _SigningIdentity(23);
      final fresh = _SigningIdentity(24);
      final rosterFounder = internal.DeviceRoster(store, founder);
      await rosterFounder.found(label: 'founder');
      await rosterFounder.admit(await sponsor.publicKey, label: 'sponsor');
      final rosterSponsor = internal.DeviceRoster(store, sponsor);
      expect(await rosterSponsor.resolve(), DeviceState.ready);
      await rosterSponsor.admit(await introduced.publicKey, label: 'phone');
      await rosterFounder.revoke(sponsor.deviceId);

      final rosterFresh = internal.DeviceRoster(store, fresh);
      final standing = {
        for (final d in await rosterFresh.devices()) d.id: d.revoked,
      };
      expect(standing[introduced.deviceId], isFalse);
      expect(standing[sponsor.deviceId], isTrue);
      final rosterIntroduced = internal.DeviceRoster(store, introduced);
      expect(await rosterIntroduced.resolve(), DeviceState.ready);
    });

    test('a record whose id is not its key\'s fingerprint is ignored',
        () async {
      // Signed by a real member, but claiming an id that belongs to no key:
      // ids must not be choosable (they decide sort order and elections).
      final claimed = DeviceRecord(
        deviceId: 'AAAAAAAAAAAAAAAA',
        publicKey: (await idE.publicKey).toBytes(),
        label: 'mislabelled',
        pairedAt: DateTime.now().toUtc(),
        signedBy: idA.deviceId,
      );
      final row = DeviceRecord(
        deviceId: claimed.deviceId,
        publicKey: claimed.publicKey,
        label: claimed.label,
        pairedAt: claimed.pairedAt,
        signedBy: claimed.signedBy,
        signature: await idA.sign(recordPayload(claimed)),
      );
      await roster.put(row);
      expect((await rosterA.devices()).map((d) => d.id),
          isNot(contains('AAAAAAAAAAAAAAAA')));
      final fresh = internal.DeviceRoster(roster, _SigningIdentity(31));
      expect((await fresh.devices()).map((d) => d.id),
          isNot(contains('AAAAAAAAAAAAAAAA')));
    });

    test('two rotations to the same epoch are both kept', () async {
      // Two devices rotating concurrently used to collide on one row id, so
      // only one of the two rotations survived anywhere.
      final rosterC = internal.DeviceRoster(roster, idC);
      expect(await rosterC.resolve(), DeviceState.ready);
      await rosterA.admit(await idE.publicKey, label: 'E');
      final epoch = rosterA.keyEpoch;
      await rosterA.revoke(idE.deviceId);
      await rosterC.revoke(idB.deviceId); // C still sits at the old epoch
      final atNext = (await roster.all())
          .whereType<KeyRotation>()
          .where((r) => r.keyEpoch == epoch + 1)
          .map((r) => r.byDeviceId)
          .toSet();
      expect(atNext, {idA.deviceId, idC.deviceId});
    });

    test('unreadable pins refuse to open instead of trusting anew', () {
      expect(
        () => internal.DeviceRoster(roster, idA, pinBytes: [1, 2, 3]),
        throwsA(isA<RosterPinsCorruptException>()),
      );
    });
  });

  group('rows this version cannot decode (F-12)', () {
    Map<String, List<Map<String, Object?>>> futureRow() {
      final hlc = Hlc.now('peer-node');
      return {
        internal.kDeviceCollection: [
          {'key': 'x', 'value': true, 'is_deleted': false, 'hlc': hlc},
          {
            'key': 'x\x1F',
            'value': {'id': 'x', 'kind': 'from-a-future-version'},
            'is_deleted': false,
            'hlc': hlc,
          },
        ],
      };
    }

    test('are dropped before a founder is pinned', () async {
      final fresh = internal.DeviceRoster(
        internal.Collection.create<DeviceRosterEntry>(
          internal.kDeviceCollection,
          internal.deviceRosterCodec,
        ),
        _SigningIdentity(41),
      );
      final vetted = await fresh.vetInbound(futureRow());
      expect(vetted[internal.kDeviceCollection], isEmpty);
    });

    test('that reach storage do not make the roster unreadable', () async {
      // As if stored by an earlier version, or by a future version's sync.
      await roster.mergeChangeset(futureRow());
      expect(await rosterA.devices(), isNotEmpty);
      expect(await rosterA.resolve(), DeviceState.ready);
    });
  });
}
