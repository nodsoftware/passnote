import 'dart:convert';
import 'dart:math';

import 'package:crdt/crdt.dart' show CrdtChangeset;

import '../codec.dart';
import '../collection.dart';
import '../ports/identity.dart';

/// The reserved collection that holds a database's device roster and the group
/// key sealed to each device.
///
/// [Database.collection] refuses this name; Passnote opens and syncs it
/// internally.
const String kDeviceCollection = '__passnote_devices';

/// Where a device sits relative to its database's group key after
/// [Passnote.openDatabase].
enum DeviceState {
  /// This device holds a valid wrap and has unwrapped the group key. User
  /// collections can be opened.
  ready,

  /// This device is not yet in the roster (or has no wrap for it). It syncs the
  /// roster but cannot open user collections until it is paired.
  needsPairing,

  /// This device's roster entry is marked revoked; the group key is withheld.
  /// Cryptographic exclusion (a key rotation) is a separate step.
  revoked,
}

/// A device in a database's roster, as reported by `Database.devices()`.
class DeviceInfo {
  /// Creates a device summary.
  const DeviceInfo({
    required this.id,
    required this.label,
    required this.pairedAt,
    required this.revoked,
    required this.isThisDevice,
    this.lastSeen,
  });

  /// The device fingerprint.
  final String id;

  /// The human-readable label.
  final String label;

  /// When the device joined the roster.
  final DateTime pairedAt;

  /// Whether the device has been revoked.
  final bool revoked;

  /// Whether this record is the device asking.
  final bool isThisDevice;

  /// When the device was last seen on the transport, or `null` if not tracked
  /// yet (the handshake does not carry the device id until a later step).
  final DateTime? lastSeen;
}

/// One row of the device roster. Every row is a [DeviceRecord], a
/// [WrappedGroupKey], or a [KeyRotation].
///
/// Every row is signed by the device that wrote it ([signedBy] /
/// [signature]): the roster key admits a device to the *room*, but only a
/// signature chained back to the founding device makes a row count. Rows with
/// a missing or invalid signature are ignored by every read path, so holding
/// the roster key alone is not enough to (re)join the roster or receive a
/// rotated group key.
sealed class DeviceRosterEntry {
  const DeviceRosterEntry();

  /// The stable document id for this row inside [kDeviceCollection].
  String get documentId;

  /// The [Identity.deviceId] of the device that wrote and signed this row.
  String get signedBy;

  /// The Ed25519 signature by [signedBy] over the row's canonical payload.
  List<int> get signature;
}

/// A paired device: its public identity plus human-facing metadata.
final class DeviceRecord extends DeviceRosterEntry {
  /// Creates a roster record. [signedBy] and [signature] are written by
  /// [DeviceRoster]; a record without a valid signature is ignored by every
  /// device.
  const DeviceRecord({
    required this.deviceId,
    required this.publicKey,
    required this.label,
    required this.pairedAt,
    this.revoked = false,
    this.signedBy = '',
    this.signature = const [],
  });

  /// The device fingerprint ([Identity.deviceId]).
  final String deviceId;

  /// The device's public identity, encoded with [DevicePublicKey.toBytes].
  final List<int> publicKey;

  /// A human-readable name for the device, e.g. `"Wouter's phone"`.
  final String label;

  /// When the device joined the roster (UTC).
  final DateTime pairedAt;

  /// Whether the device has been revoked.
  final bool revoked;

  @override
  final String signedBy;

  @override
  final List<int> signature;

  /// A copy with [label] and/or [revoked] changed. The copy carries **no**
  /// signature: the writer must re-sign it.
  DeviceRecord copyWith({String? label, bool? revoked}) => DeviceRecord(
        deviceId: deviceId,
        publicKey: publicKey,
        label: label ?? this.label,
        pairedAt: pairedAt,
        revoked: revoked ?? this.revoked,
      );

  @override
  String get documentId => 'device:$deviceId';
}

/// The group key, sealed to one device at one key epoch.
final class WrappedGroupKey extends DeviceRosterEntry {
  /// Creates a wrap row. [signedBy] and [signature] are written by
  /// [DeviceRoster]; a wrap without a valid signature is never unwrapped, so a
  /// key injected by a non-member (or a revoked member) is never adopted.
  const WrappedGroupKey({
    required this.deviceId,
    required this.keyEpoch,
    required this.wrappedBytes,
    this.signedBy = '',
    this.signature = const [],
  });

  /// The device this wrap is sealed to.
  final String deviceId;

  /// The key epoch this wrap carries. Rotation bumps it.
  final int keyEpoch;

  /// The sealed key, encoded with [WrappedKey.toBytes].
  final List<int> wrappedBytes;

  @override
  final String signedBy;

  @override
  final List<int> signature;

  @override
  String get documentId => 'wrap:$deviceId:$keyEpoch';
}

/// A record that the group key was rotated to [keyEpoch], excluding
/// [revokedDeviceId] (empty for the initial founding at epoch 0).
///
/// One per epoch; concurrent rotations to the same epoch converge to a single
/// record by last-write-wins, and [DeviceRoster.reconcile] re-rotates if that
/// leaves a revoked device holding a usable wrap.
final class KeyRotation extends DeviceRosterEntry {
  /// Creates a rotation row, signed by [byDeviceId].
  const KeyRotation({
    required this.keyEpoch,
    required this.byDeviceId,
    required this.revokedDeviceId,
    required this.keyDigest,
    this.signature = const [],
  });

  /// The epoch this rotation produced.
  final int keyEpoch;

  /// The device that performed the rotation (and signed this row).
  final String byDeviceId;

  /// The device excluded by this rotation (`''` for founding).
  final String revokedDeviceId;

  /// A short non-secret digest of the new key, to spot competing rotations.
  final List<int> keyDigest;

  @override
  String get signedBy => byDeviceId;

  @override
  final List<int> signature;

  @override
  String get documentId => 'rotation:$keyEpoch';
}

/// Codec for the reserved [kDeviceCollection]. Rows are discriminated by a
/// `kind` field; byte fields are base64.
final Codec<DeviceRosterEntry> deviceRosterCodec = JsonCodec<DeviceRosterEntry>(
  idOf: (e) => e.documentId,
  toMap: (e) => switch (e) {
    DeviceRecord() => {
        'id': e.documentId,
        'kind': 'device',
        'deviceId': e.deviceId,
        'publicKey': base64.encode(e.publicKey),
        'label': e.label,
        'pairedAt': e.pairedAt.toUtc().toIso8601String(),
        'revoked': e.revoked,
        'signedBy': e.signedBy,
        'signature': base64.encode(e.signature),
      },
    WrappedGroupKey() => {
        'id': e.documentId,
        'kind': 'wrap',
        'deviceId': e.deviceId,
        'keyEpoch': e.keyEpoch,
        'wrappedBytes': base64.encode(e.wrappedBytes),
        'signedBy': e.signedBy,
        'signature': base64.encode(e.signature),
      },
    KeyRotation() => {
        'id': e.documentId,
        'kind': 'rotation',
        'keyEpoch': e.keyEpoch,
        'byDeviceId': e.byDeviceId,
        'revokedDeviceId': e.revokedDeviceId,
        'keyDigest': base64.encode(e.keyDigest),
        'signature': base64.encode(e.signature),
      },
  },
  fromMap: (m) => switch (m['kind']) {
    'device' => DeviceRecord(
        deviceId: m['deviceId'] as String,
        publicKey: base64.decode(m['publicKey'] as String),
        label: m['label'] as String,
        pairedAt: DateTime.parse(m['pairedAt'] as String),
        revoked: (m['revoked'] as bool?) ?? false,
        signedBy: (m['signedBy'] as String?) ?? '',
        signature: base64.decode((m['signature'] as String?) ?? ''),
      ),
    'wrap' => WrappedGroupKey(
        deviceId: m['deviceId'] as String,
        keyEpoch: (m['keyEpoch'] as num).toInt(),
        wrappedBytes: base64.decode(m['wrappedBytes'] as String),
        signedBy: (m['signedBy'] as String?) ?? '',
        signature: base64.decode((m['signature'] as String?) ?? ''),
      ),
    'rotation' => KeyRotation(
        keyEpoch: (m['keyEpoch'] as num).toInt(),
        byDeviceId: m['byDeviceId'] as String,
        revokedDeviceId: m['revokedDeviceId'] as String,
        keyDigest: base64.decode(m['keyDigest'] as String),
        signature: base64.decode((m['signature'] as String?) ?? ''),
      ),
    final other =>
      throw FormatException('unknown device roster row kind: $other'),
  },
);

/// The rows of the roster that passed signature validation, plus the trust
/// state they were validated against.
class _RosterView {
  _RosterView({
    required this.records,
    required this.wraps,
    required this.revoked,
  });

  /// One validated [DeviceRecord] per known device id.
  final Map<String, DeviceRecord> records;

  /// Validated wraps (signed by a known, non-revoked device).
  final List<WrappedGroupKey> wraps;

  /// Every device id revoked by a validated rotation row or record flag.
  final Set<String> revoked;
}

/// Orchestrates the reserved roster collection: resolves this device's group-key
/// state on open, and provides the founding / admit / revoke write paths.
///
/// ## Row authentication
///
/// Every row is Ed25519-signed by its writer and validated on every read:
///
/// - The **founder** is the device named by the self-signed `rotation:0` row;
///   its identity is pinned on first sight and never re-learned.
/// - A [DeviceRecord] counts only when signed by an already-known,
///   non-revoked device (the founder is the root; admission at pairing and
///   recovery creates the edges). A known device's public key is pinned; a
///   record that changes it is ignored.
/// - A [KeyRotation] counts only when signed by a known, non-revoked device.
///   Revocation is monotone: once a device id is seen revoked it stays
///   revoked, so a revoked device cannot rotate, admit, or re-admit itself
///   under a fresh id — even though it still holds the roster key.
/// - A [WrappedGroupKey] is unwrapped only when signed by a known,
///   non-revoked device, so a key injected by an outsider or a revoked member
///   is never adopted.
///
/// The pinned trust state (founder, known device keys, revoked ids) is
/// local and monotone; [Database] persists it in the [KeyStore] so it
/// survives restarts. A device that first syncs a roster it has never seen
/// necessarily trusts the snapshot it receives (the same trust-on-first-use
/// as the pairing exchange that admitted it).
///
/// Not exported. [Database] owns one when an [Identity] is configured.
class DeviceRoster {
  /// Creates the orchestrator over the reserved roster [Collection].
  ///
  /// [pinBytes] restores previously persisted trust pins; [savePins] is called
  /// with the new encoding whenever the pins grow.
  DeviceRoster(
    this._collection,
    this._identity, {
    List<int>? pinBytes,
    Future<void> Function(List<int> bytes)? savePins,
  }) : _savePins = savePins {
    if (pinBytes != null) _loadPins(pinBytes);
  }

  final Collection<DeviceRosterEntry> _collection;
  final Identity _identity;
  final Future<void> Function(List<int> bytes)? _savePins;

  List<int>? _groupKey;
  int _epoch = 0;
  DeviceState _state = DeviceState.needsPairing;

  /// Monotone local trust pins: the founder, every known device's public key,
  /// and every revoked id. See the class docs.
  String? _founderId;
  final Map<String, List<int>> _known = {};
  final Set<String> _revoked = {};

  /// Memoised signature checks, keyed by payload ‖ signature ‖ signer key.
  /// Bounded: verification of hostile input must not grow memory (failures
  /// are cached too), so the oldest entry is evicted at the cap. The
  /// legitimate roster is far smaller than the cap.
  final Map<String, bool> _verifyCache = {};

  /// Upper bound on [_verifyCache] entries.
  static const int _verifyCacheCap = 512;

  /// Completes when the roster collection's initial load has finished.
  Future<void> get ready => _collection.ready;

  /// The unwrapped group key, or `null` unless [state] is [DeviceState.ready].
  List<int>? get groupKey => _state == DeviceState.ready ? _groupKey : null;

  /// This device's current group-key state.
  DeviceState get state => _state;

  /// The key epoch this device currently holds.
  int get keyEpoch => _epoch;

  // ---------------------------------------------------------------------------
  // Row signatures

  static String _b64(List<int> bytes) => base64.encode(bytes);

  /// The canonical byte payload a row's signature covers.
  static List<int> _payload(DeviceRosterEntry row) {
    final fields = switch (row) {
      DeviceRecord() => [
          'passnote-roster-device-v1',
          row.deviceId,
          _b64(row.publicKey),
          row.label,
          row.pairedAt.toUtc().toIso8601String(),
          row.revoked.toString(),
          row.signedBy,
        ],
      WrappedGroupKey() => [
          'passnote-roster-wrap-v1',
          row.deviceId,
          row.keyEpoch.toString(),
          _b64(row.wrappedBytes),
          row.signedBy,
        ],
      KeyRotation() => [
          'passnote-roster-rotation-v1',
          row.keyEpoch.toString(),
          row.byDeviceId,
          row.revokedDeviceId,
          _b64(row.keyDigest),
        ],
    };
    return utf8.encode(fields.join('\x1F'));
  }

  /// Whether [row]'s signature verifies against [signerKey] (a
  /// [DevicePublicKey.toBytes] encoding). Memoised.
  Future<bool> _verifyRow(DeviceRosterEntry row, List<int> signerKey) async {
    if (row.signature.isEmpty || signerKey.length != 64) return false;
    final payload = _payload(row);
    final cacheKey = '${_b64(payload)}|${_b64(row.signature)}|'
        '${_b64(signerKey)}';
    final cached = _verifyCache[cacheKey];
    if (cached != null) return cached;
    final ok = await _identity.verify(
      payload,
      signature: row.signature,
      signer: DevicePublicKey.fromBytes(signerKey),
    );
    if (_verifyCache.length >= _verifyCacheCap) {
      _verifyCache.remove(_verifyCache.keys.first);
    }
    _verifyCache[cacheKey] = ok;
    return ok;
  }

  /// Writes [record] with this instance's fields signed by [signer]
  /// (defaults to this device).
  Future<DeviceRecord> _signRecord(
    DeviceRecord record, {
    Identity? signer,
  }) async {
    final identity = signer ?? _identity;
    final unsigned = DeviceRecord(
      deviceId: record.deviceId,
      publicKey: record.publicKey,
      label: record.label,
      pairedAt: record.pairedAt,
      revoked: record.revoked,
      signedBy: identity.deviceId,
    );
    return DeviceRecord(
      deviceId: unsigned.deviceId,
      publicKey: unsigned.publicKey,
      label: unsigned.label,
      pairedAt: unsigned.pairedAt,
      revoked: unsigned.revoked,
      signedBy: unsigned.signedBy,
      signature: await identity.sign(_payload(unsigned)),
    );
  }

  Future<WrappedGroupKey> _signWrap(
    WrappedGroupKey wrap, {
    Identity? signer,
  }) async {
    final identity = signer ?? _identity;
    final unsigned = WrappedGroupKey(
      deviceId: wrap.deviceId,
      keyEpoch: wrap.keyEpoch,
      wrappedBytes: wrap.wrappedBytes,
      signedBy: identity.deviceId,
    );
    return WrappedGroupKey(
      deviceId: unsigned.deviceId,
      keyEpoch: unsigned.keyEpoch,
      wrappedBytes: unsigned.wrappedBytes,
      signedBy: unsigned.signedBy,
      signature: await identity.sign(_payload(unsigned)),
    );
  }

  Future<KeyRotation> _signRotation(KeyRotation rotation) async {
    return KeyRotation(
      keyEpoch: rotation.keyEpoch,
      byDeviceId: rotation.byDeviceId,
      revokedDeviceId: rotation.revokedDeviceId,
      keyDigest: rotation.keyDigest,
      signature: await _identity.sign(_payload(rotation)),
    );
  }

  // ---------------------------------------------------------------------------
  // Validation

  /// Validates the roster against the pinned trust state and returns only the
  /// rows that count. Grows the pins (monotone) and persists them when they
  /// changed.
  Future<_RosterView> _validate() async {
    final rows = await _collection.all();
    final records = rows.whereType<DeviceRecord>().toList();
    final rotations = rows.whereType<KeyRotation>().toList()
      ..sort((a, b) => a.keyEpoch.compareTo(b.keyEpoch));
    final wraps = rows.whereType<WrappedGroupKey>().toList();

    final pinSnapshot = _pinFingerprint();

    // This device always knows its own identity.
    _known[_identity.deviceId] ??= (await _identity.publicKey).toBytes();

    // Pin the founder from the self-signed founding rotation, once.
    if (_founderId == null) {
      KeyRotation? rot0;
      for (final r in rotations) {
        if (r.keyEpoch == 0 && r.revokedDeviceId.isEmpty) rot0 = r;
      }
      if (rot0 != null) {
        DeviceRecord? founderRecord;
        for (final r in records) {
          if (r.deviceId == rot0.byDeviceId && r.signedBy == r.deviceId) {
            founderRecord = r;
          }
        }
        if (founderRecord != null &&
            await _verifyRow(founderRecord, founderRecord.publicKey) &&
            await _verifyRow(rot0, founderRecord.publicKey)) {
          _founderId = founderRecord.deviceId;
          _known[founderRecord.deviceId] ??= founderRecord.publicKey;
        }
      }
    }

    // Fixed point: rotations by known non-revoked signers extend the revoked
    // set; records signed by known non-revoked signers extend the known set.
    // Both sets only grow, so this terminates.
    var changed = true;
    while (changed) {
      changed = false;

      for (final rot in rotations) {
        if (rot.revokedDeviceId.isEmpty) continue;
        if (_revoked.contains(rot.revokedDeviceId)) continue;
        final signerKey = _known[rot.byDeviceId];
        if (signerKey == null || _revoked.contains(rot.byDeviceId)) continue;
        if (await _verifyRow(rot, signerKey)) {
          _revoked.add(rot.revokedDeviceId);
          changed = true;
        }
      }

      for (final rec in records) {
        final signerKey = _known[rec.signedBy];
        if (signerKey == null || _revoked.contains(rec.signedBy)) continue;
        final knownKey = _known[rec.deviceId];
        if (knownKey != null) {
          // Key continuity: a known device never changes its public key.
          if (!_sameKey(knownKey, rec.publicKey)) continue;
          if (rec.revoked &&
              !_revoked.contains(rec.deviceId) &&
              await _verifyRow(rec, signerKey)) {
            _revoked.add(rec.deviceId);
            changed = true;
          }
          continue;
        }
        // A device may not introduce itself; only the pinned founder is
        // self-signed (validated above).
        if (rec.signedBy == rec.deviceId) continue;
        if (await _verifyRow(rec, signerKey)) {
          _known[rec.deviceId] = List<int>.unmodifiable(rec.publicKey);
          changed = true;
        }
      }
    }

    // Assemble the validated view.
    final validRecords = <String, DeviceRecord>{};
    for (final rec in records) {
      final knownKey = _known[rec.deviceId];
      if (knownKey == null || !_sameKey(knownKey, rec.publicKey)) continue;
      final signerKey = _known[rec.signedBy];
      if (signerKey == null) continue;
      if (await _verifyRow(rec, signerKey)) validRecords[rec.deviceId] = rec;
    }
    final validWraps = <WrappedGroupKey>[];
    for (final wrap in wraps) {
      final signerKey = _known[wrap.signedBy];
      if (signerKey == null || _revoked.contains(wrap.signedBy)) continue;
      if (await _verifyRow(wrap, signerKey)) validWraps.add(wrap);
    }

    if (_pinFingerprint() != pinSnapshot) await _persistPins();

    return _RosterView(
      records: validRecords,
      wraps: validWraps,
      revoked: Set.unmodifiable(_revoked),
    );
  }

  String _pinFingerprint() =>
      '${_founderId ?? ''}|${_known.keys.toList()..sort()}|'
      '${_revoked.toList()..sort()}';

  Future<void> _persistPins() async {
    final save = _savePins;
    if (save == null) return;
    await save(utf8.encode(jsonEncode({
      'founder': _founderId,
      'known': {for (final e in _known.entries) e.key: _b64(e.value)},
      'revoked': _revoked.toList()..sort(),
    })));
  }

  void _loadPins(List<int> bytes) {
    try {
      final map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      _founderId = map['founder'] as String?;
      for (final e in (map['known'] as Map<String, dynamic>).entries) {
        _known[e.key] = base64.decode(e.value as String);
      }
      _revoked.addAll((map['revoked'] as List).cast<String>());
    } catch (_) {
      // Unreadable pins degrade to trust-on-first-use, never to a crash.
    }
  }

  // ---------------------------------------------------------------------------
  // Reads

  /// The roster's validated device records, oldest first.
  Future<List<DeviceRecord>> listDevices() async {
    final view = await _validate();
    return view.records.values.toList()
      ..sort((a, b) => a.pairedAt.compareTo(b.pairedAt));
  }

  /// The validated roster as [DeviceInfo], oldest first, with revocation
  /// resolved from both rotation records and record flags.
  Future<List<DeviceInfo>> devices() async {
    final view = await _validate();
    final myId = _identity.deviceId;
    return [
      for (final d
          in view.records.values.toList()
            ..sort((a, b) => a.pairedAt.compareTo(b.pairedAt)))
        DeviceInfo(
          id: d.deviceId,
          label: d.label,
          pairedAt: d.pairedAt,
          revoked: d.revoked || view.revoked.contains(d.deviceId),
          isThisDevice: d.deviceId == myId,
        ),
    ];
  }

  /// The public identity of [deviceId] when it is a validated, non-revoked
  /// roster member, else `null`. Sessions are only ever opened with devices
  /// this returns a key for.
  Future<DevicePublicKey?> memberKey(String deviceId) async {
    final view = await _validate();
    if (view.revoked.contains(deviceId)) return null;
    final record = view.records[deviceId];
    if (record == null) return null;
    return DevicePublicKey.fromBytes(record.publicKey);
  }

  /// `true` while no device has founded the group key yet (no validated wrap
  /// exists).
  Future<bool> get isUnfounded async {
    final view = await _validate();
    return view.wraps.isEmpty;
  }

  /// Filters an inbound roster [changeset] down to the rows this device will
  /// accept, so junk written by a non-member is never persisted or merged.
  /// A revoked device still holds the roster key and can send frames; without
  /// this gate its rows would occupy disk on every peer forever, since roster
  /// rows are live records that compaction never reclaims.
  ///
  /// Admission is per document (a document's existence register and value
  /// record always travel in the same frame):
  ///
  /// - Tombstones are dropped. No roster row is ever legitimately deleted
  ///   (rename and revocation overwrite rows), and accepting a deletion would
  ///   let any roster-key holder erase membership state.
  /// - A row is admitted when its writer is a known, non-revoked member and
  ///   its signature verifies — the same rule reads apply. A [DeviceRecord]
  ///   admitted this way makes its device known for the rest of the
  ///   changeset, so a sponsor's admission and the new device's first rows
  ///   can share a frame.
  /// - Until this device has pinned a founder (its own first sight of a
  ///   roster), everything is admitted: the trust-on-first-use window that
  ///   pairing already implies. Read-time validation still governs what is
  ///   acted on.
  ///
  /// A dropped row whose signer this device merely has not learned yet is not
  /// lost: range reconciliation re-offers it until its chain has arrived.
  Future<CrdtChangeset> vetInbound(CrdtChangeset changeset) async {
    if (_founderId == null) return changeset;

    final out = <String, List<Map<String, Object?>>>{};
    for (final entry in changeset.entries) {
      // Group records by document id; keys are `docId` (existence register)
      // and `docId\x1F` (the whole-document value record).
      final byDoc = <String, List<Map<String, Object?>>>{};
      for (final record in entry.value) {
        final key = record['key'] as String;
        final sep = key.indexOf('\x1F');
        final docId = sep < 0 ? key : key.substring(0, sep);
        (byDoc[docId] ??= []).add(record);
      }

      // Rows admitted so far this changeset can vouch for later ones (the
      // sponsor's DeviceRecord for a new device arrives alongside rows that
      // device signed). Retry only the groups waiting on a newly known
      // signer, so hostile input costs one verification per row.
      final known = {..._known};
      final admitted = <List<Map<String, Object?>>>[];
      final waiting = <String, List<(String, DeviceRosterEntry)>>{};

      Future<void> admitChain(String signerId) async {
        final queue = [signerId];
        while (queue.isNotEmpty) {
          final retries = waiting.remove(queue.removeLast()) ?? const [];
          for (final (docId, row) in retries) {
            final signerKey = known[row.signedBy];
            if (signerKey == null || _revoked.contains(row.signedBy)) continue;
            if (!await _verifyRow(row, signerKey)) continue;
            admitted.add(byDoc[docId]!);
            if (row is DeviceRecord && !known.containsKey(row.deviceId)) {
              known[row.deviceId] = row.publicKey;
              queue.add(row.deviceId);
            }
          }
        }
      }

      for (final group in byDoc.entries) {
        // Tombstones and rows without a decodable value record are refused.
        if (group.value.any((r) => r['is_deleted'] == true)) continue;
        Map<String, Object?>? valueRecord;
        for (final r in group.value) {
          if ((r['key'] as String).contains('\x1F')) valueRecord = r;
        }
        if (valueRecord == null) continue;
        final DeviceRosterEntry row;
        try {
          row = deviceRosterCodec.fromMap(
            (valueRecord['value'] as Map).cast<String, dynamic>(),
          );
        } catch (_) {
          continue;
        }
        if (row.signature.isEmpty) continue;
        final signerKey = known[row.signedBy];
        if (signerKey == null) {
          // The signer may become known later in this changeset.
          (waiting[row.signedBy] ??= []).add((group.key, row));
          continue;
        }
        if (_revoked.contains(row.signedBy)) continue;
        if (!await _verifyRow(row, signerKey)) continue;
        admitted.add(group.value);
        if (row is DeviceRecord && !known.containsKey(row.deviceId)) {
          known[row.deviceId] = row.publicKey;
          await admitChain(row.deviceId);
        }
      }

      out[entry.key] = [for (final group in admitted) ...group];
    }
    return out;
  }

  /// Re-reads the roster and recomputes [state] / [groupKey]. Returns the new
  /// state. Call after sync has delivered roster rows from a peer.
  Future<DeviceState> resolve() async {
    await _collection.ready;
    final view = await _validate();
    final myId = _identity.deviceId;

    if (view.revoked.contains(myId)) {
      _groupKey = null;
      return _state = DeviceState.revoked;
    }

    final myWraps = view.wraps.where((w) => w.deviceId == myId).toList()
      ..sort((a, b) => a.keyEpoch.compareTo(b.keyEpoch));
    if (myWraps.isEmpty) {
      _groupKey = null;
      return _state = DeviceState.needsPairing;
    }

    final latest = myWraps.last;
    _groupKey =
        await _identity.unwrap(WrappedKey.fromBytes(latest.wrappedBytes));
    _epoch = latest.keyEpoch;
    return _state = DeviceState.ready;
  }

  /// After a roster merge, adopt a newer group key this device now has a wrap
  /// for, and — if a revoked device still holds a usable wrap at the live epoch
  /// (which happens when two revocations raced) — perform one more rotation to
  /// close that gap. Only the lowest-id non-revoked device re-rotates, so the
  /// process is deterministic and terminates.
  ///
  /// Returns the new group key when it changed, else `null`.
  Future<List<int>?> reconcile() async {
    if (_state == DeviceState.revoked) return null;
    final before = _groupKey;
    await resolve();
    if (_state != DeviceState.ready) {
      return _sameKey(before, _groupKey) ? null : _groupKey;
    }

    final view = await _validate();
    final leakers = view.wraps
        .where((w) => w.keyEpoch == _epoch && view.revoked.contains(w.deviceId))
        .map((w) => w.deviceId)
        .toSet();
    if (leakers.isNotEmpty && _isElectedRotator(view)) {
      await _rotateExcluding(view);
    }
    return _sameKey(before, _groupKey) ? null : _groupKey;
  }

  // ---------------------------------------------------------------------------
  // Writes

  /// Generates the group key for a brand-new database and seals it to this
  /// device at epoch 0, writing the self-signed founding rotation row that
  /// roots the roster's trust chain. Throws [StateError] if the roster already
  /// carries a wrap (another device founded it — pair instead).
  Future<void> found({required String label}) async {
    if (!await isUnfounded) {
      throw StateError(
        'This database already has a group key. Pair this device instead of '
        'founding a new group.',
      );
    }
    final me = await _identity.publicKey;
    final groupKey = _randomKey();
    await _collection.put(await _signRotation(KeyRotation(
      keyEpoch: 0,
      byDeviceId: _identity.deviceId,
      revokedDeviceId: '',
      keyDigest: _digest8(groupKey),
    )));
    await _writeWrap(
      publicKey: me,
      deviceId: _identity.deviceId,
      label: label,
      groupKey: groupKey,
      epoch: 0,
    );
    _founderId ??= _identity.deviceId;
    _known[_identity.deviceId] ??= me.toBytes();
    await _persistPins();
    _groupKey = groupKey;
    _epoch = 0;
    _state = DeviceState.ready;
  }

  /// Adds [peer] to the roster and seals the current group key to it. Callable
  /// only from [DeviceState.ready]. Used by the pairing flow once a new device
  /// has been authenticated.
  Future<void> admit(DevicePublicKey peer, {required String label}) async {
    final key = groupKey;
    if (key == null) {
      throw StateError('This device does not hold the group key.');
    }
    await _writeWrap(
      publicKey: peer,
      deviceId: _identity.fingerprintOf(peer),
      label: label,
      groupKey: key,
      epoch: _epoch,
    );
  }

  /// Recovers membership through [recovery], a virtual device derived from a
  /// recovery phrase: unwraps the latest group-key wrap sealed to it, adopts
  /// the key, and admits this physical device to the roster as [label]. The
  /// new device's rows are signed by [recovery], which is a roster member, so
  /// peers accept them.
  ///
  /// Returns `false` when the roster holds no wrap for [recovery] yet (rows
  /// may still be syncing in — retry after more sync). Throws [StateError]
  /// when [recovery]'s roster entry has been revoked: a withdrawn phrase must
  /// not regain access.
  Future<bool> adoptVia(Identity recovery, {required String label}) async {
    final view = await _validate();
    final recoveryId = recovery.deviceId;
    if (view.revoked.contains(recoveryId)) {
      throw StateError(
        'This recovery phrase has been revoked and can no longer restore '
        'access.',
      );
    }
    final wraps = view.wraps.where((w) => w.deviceId == recoveryId).toList()
      ..sort((a, b) => a.keyEpoch.compareTo(b.keyEpoch));
    if (wraps.isEmpty) return false;

    final latest = wraps.last;
    final groupKey =
        await recovery.unwrap(WrappedKey.fromBytes(latest.wrappedBytes));
    _groupKey = groupKey;
    _epoch = latest.keyEpoch;
    _state = DeviceState.ready;

    await _writeWrap(
      publicKey: await _identity.publicKey,
      deviceId: _identity.deviceId,
      label: label,
      groupKey: groupKey,
      epoch: latest.keyEpoch,
      signer: recovery,
    );
    return true;
  }

  /// Revokes [deviceId]: rotates the group key to the next epoch, seals it to
  /// every non-revoked device except [deviceId], and marks [deviceId] revoked.
  /// Returns the new group key.
  ///
  /// Callable only from [DeviceState.ready].
  Future<List<int>> revoke(String deviceId) async {
    if (_state != DeviceState.ready) {
      throw StateError('This device does not hold the group key.');
    }
    final view = await _validate();
    if (!view.records.containsKey(deviceId)) {
      throw StateError('No device "$deviceId" in the roster.');
    }
    _revoked.add(deviceId);
    await _persistPins();
    await _rotateExcluding(view, newlyRevoked: deviceId);
    return _groupKey!;
  }

  /// Changes the label on [deviceId]'s roster record, re-signing it as this
  /// device.
  Future<void> rename(String deviceId, String label) async {
    final view = await _validate();
    final record = view.records[deviceId];
    if (record == null) {
      throw StateError('No device "$deviceId" in the roster.');
    }
    await _collection.put(await _signRecord(record.copyWith(label: label)));
  }

  /// True when this device should be the one to re-rotate: the lowest device id
  /// among the non-revoked devices.
  bool _isElectedRotator(_RosterView view) {
    final active = view.records.keys
        .where((id) => !view.revoked.contains(id))
        .toList()
      ..sort();
    return active.isNotEmpty && active.first == _identity.deviceId;
  }

  /// Rotates to `_epoch + 1`: fresh key, one wrap per validated non-revoked
  /// device, one [KeyRotation] record, and the [DeviceRecord] flag for
  /// [newlyRevoked]. Only records that passed signature validation receive a
  /// wrap, so a forged roster entry never obtains a rotated key.
  Future<void> _rotateExcluding(
    _RosterView view, {
    String? newlyRevoked,
  }) async {
    final nextEpoch = _epoch + 1;
    final newKey = _randomKey();

    for (final device in view.records.values) {
      if (view.revoked.contains(device.deviceId)) continue;
      if (device.deviceId == newlyRevoked) continue;
      final wrapped = await _identity.wrapFor(
        DevicePublicKey.fromBytes(device.publicKey),
        newKey,
      );
      await _collection.put(await _signWrap(WrappedGroupKey(
        deviceId: device.deviceId,
        keyEpoch: nextEpoch,
        wrappedBytes: wrapped.toBytes(),
      )));
    }
    await _collection.put(await _signRotation(KeyRotation(
      keyEpoch: nextEpoch,
      byDeviceId: _identity.deviceId,
      revokedDeviceId: newlyRevoked ?? '',
      keyDigest: _digest8(newKey),
    )));
    if (newlyRevoked != null) {
      final record = view.records[newlyRevoked];
      if (record != null) {
        await _collection.put(
          await _signRecord(record.copyWith(revoked: true)),
        );
      }
    }

    _groupKey = newKey;
    _epoch = nextEpoch;
    _state = DeviceState.ready;
  }

  static bool _sameKey(List<int>? a, List<int>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<int> _digest8(List<int> key) {
    var h = 0x811c9dc5;
    for (final b in key) {
      h = ((h ^ b) * 0x01000193) & 0xffffffff;
    }
    return [
      for (var i = 0; i < 8; i++) (h >> ((i % 4) * 8)) & 0xff,
    ];
  }

  Future<void> _writeWrap({
    required DevicePublicKey publicKey,
    required String deviceId,
    required String label,
    required List<int> groupKey,
    required int epoch,
    Identity? signer,
  }) async {
    final signingIdentity = signer ?? _identity;
    final wrapped = await signingIdentity.wrapFor(publicKey, groupKey);
    await _collection.put(
      await _signWrap(
        WrappedGroupKey(
          deviceId: deviceId,
          keyEpoch: epoch,
          wrappedBytes: wrapped.toBytes(),
        ),
        signer: signer,
      ),
    );
    await _collection.put(
      await _signRecord(
        DeviceRecord(
          deviceId: deviceId,
          publicKey: publicKey.toBytes(),
          label: label,
          pairedAt: DateTime.now().toUtc(),
        ),
        signer: signer,
      ),
    );
  }

  static List<int> _randomKey() {
    final rng = Random.secure();
    return List<int>.generate(32, (_) => rng.nextInt(256));
  }
}
