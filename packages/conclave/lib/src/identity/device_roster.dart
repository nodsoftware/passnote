import 'dart:convert';
import 'dart:math';

import '../codec.dart';
import '../collection.dart';
import '../ports/identity.dart';

/// The reserved collection that holds a database's device roster and the group
/// key sealed to each device.
///
/// [Database.collection] refuses this name; Conclave opens and syncs it
/// internally.
const String kDeviceCollection = '__conclave_devices';

/// Where a device sits relative to its database's group key after
/// [Conclave.openDatabase].
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
sealed class DeviceRosterEntry {
  const DeviceRosterEntry();

  /// The stable document id for this row inside [kDeviceCollection].
  String get documentId;
}

/// A paired device: its public identity plus human-facing metadata.
final class DeviceRecord extends DeviceRosterEntry {
  /// Creates a roster record.
  const DeviceRecord({
    required this.deviceId,
    required this.publicKey,
    required this.label,
    required this.pairedAt,
    this.revoked = false,
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

  /// A copy with [label] and/or [revoked] changed.
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
  /// Creates a wrap row.
  const WrappedGroupKey({
    required this.deviceId,
    required this.keyEpoch,
    required this.wrappedBytes,
  });

  /// The device this wrap is sealed to.
  final String deviceId;

  /// The key epoch this wrap carries. Rotation bumps it.
  final int keyEpoch;

  /// The sealed key, encoded with [WrappedKey.toBytes].
  final List<int> wrappedBytes;

  @override
  String get documentId => 'wrap:$deviceId:$keyEpoch';
}

/// A record that the group key was rotated to [keyEpoch], excluding
/// [revokedDeviceId] (empty for the initial founding).
///
/// One per epoch; concurrent rotations to the same epoch converge to a single
/// record by last-write-wins, and [DeviceRoster.reconcile] re-rotates if that
/// leaves a revoked device holding a usable wrap.
final class KeyRotation extends DeviceRosterEntry {
  /// Creates a rotation row.
  const KeyRotation({
    required this.keyEpoch,
    required this.byDeviceId,
    required this.revokedDeviceId,
    required this.keyDigest,
  });

  /// The epoch this rotation produced.
  final int keyEpoch;

  /// The device that performed the rotation.
  final String byDeviceId;

  /// The device excluded by this rotation (`''` for founding).
  final String revokedDeviceId;

  /// A short non-secret digest of the new key, to spot competing rotations.
  final List<int> keyDigest;

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
      },
    WrappedGroupKey() => {
        'id': e.documentId,
        'kind': 'wrap',
        'deviceId': e.deviceId,
        'keyEpoch': e.keyEpoch,
        'wrappedBytes': base64.encode(e.wrappedBytes),
      },
    KeyRotation() => {
        'id': e.documentId,
        'kind': 'rotation',
        'keyEpoch': e.keyEpoch,
        'byDeviceId': e.byDeviceId,
        'revokedDeviceId': e.revokedDeviceId,
        'keyDigest': base64.encode(e.keyDigest),
      },
  },
  fromMap: (m) => switch (m['kind']) {
    'device' => DeviceRecord(
        deviceId: m['deviceId'] as String,
        publicKey: base64.decode(m['publicKey'] as String),
        label: m['label'] as String,
        pairedAt: DateTime.parse(m['pairedAt'] as String),
        revoked: (m['revoked'] as bool?) ?? false,
      ),
    'wrap' => WrappedGroupKey(
        deviceId: m['deviceId'] as String,
        keyEpoch: (m['keyEpoch'] as num).toInt(),
        wrappedBytes: base64.decode(m['wrappedBytes'] as String),
      ),
    'rotation' => KeyRotation(
        keyEpoch: (m['keyEpoch'] as num).toInt(),
        byDeviceId: m['byDeviceId'] as String,
        revokedDeviceId: m['revokedDeviceId'] as String,
        keyDigest: base64.decode(m['keyDigest'] as String),
      ),
    final other =>
      throw FormatException('unknown device roster row kind: $other'),
  },
);

/// Orchestrates the reserved roster collection: resolves this device's group-key
/// state on open, and provides the founding / admit / revoke write paths.
///
/// Not exported. [Database] owns one when an [Identity] is configured.
class DeviceRoster {
  /// Creates the orchestrator over the reserved roster [Collection].
  DeviceRoster(this._collection, this._identity);

  final Collection<DeviceRosterEntry> _collection;
  final Identity _identity;

  List<int>? _groupKey;
  int _epoch = 0;
  DeviceState _state = DeviceState.needsPairing;

  /// Completes when the roster collection's initial load has finished.
  Future<void> get ready => _collection.ready;

  /// The unwrapped group key, or `null` unless [state] is [DeviceState.ready].
  List<int>? get groupKey => _state == DeviceState.ready ? _groupKey : null;

  /// This device's current group-key state.
  DeviceState get state => _state;

  /// The key epoch this device currently holds.
  int get keyEpoch => _epoch;

  /// The roster's device records, oldest first.
  Future<List<DeviceRecord>> listDevices() async {
    final rows = await _collection.all();
    return rows.whereType<DeviceRecord>().toList()
      ..sort((a, b) => a.pairedAt.compareTo(b.pairedAt));
  }

  /// The roster as [DeviceInfo], oldest first, with revocation resolved from
  /// both rotation records and record flags.
  Future<List<DeviceInfo>> devices() async {
    final rows = await _collection.all();
    final revoked = _revokedIds(rows);
    final myId = _identity.deviceId;
    return [
      for (final d
          in rows.whereType<DeviceRecord>().toList()
            ..sort((a, b) => a.pairedAt.compareTo(b.pairedAt)))
        DeviceInfo(
          id: d.deviceId,
          label: d.label,
          pairedAt: d.pairedAt,
          revoked: d.revoked || revoked.contains(d.deviceId),
          isThisDevice: d.deviceId == myId,
        ),
    ];
  }

  /// `true` while no device has founded the group key yet.
  Future<bool> get isUnfounded async {
    final rows = await _collection.all();
    return rows.whereType<WrappedGroupKey>().isEmpty;
  }

  /// Re-reads the roster and recomputes [state] / [groupKey]. Returns the new
  /// state. Call after sync has delivered roster rows from a peer.
  Future<DeviceState> resolve() async {
    await _collection.ready;
    final rows = await _collection.all();
    final myId = _identity.deviceId;

    if (_revokedIds(rows).contains(myId)) {
      _groupKey = null;
      return _state = DeviceState.revoked;
    }

    final myWraps = rows
        .whereType<WrappedGroupKey>()
        .where((w) => w.deviceId == myId)
        .toList()
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

    final rows = await _collection.all();
    final revoked = _revokedIds(rows);
    final leakers = rows
        .whereType<WrappedGroupKey>()
        .where((w) => w.keyEpoch == _epoch && revoked.contains(w.deviceId))
        .map((w) => w.deviceId)
        .toSet();
    if (leakers.isNotEmpty && _isElectedRotator(rows, revoked)) {
      await _rotateExcluding(revoked, rows);
    }
    return _sameKey(before, _groupKey) ? null : _groupKey;
  }

  /// Generates the group key for a brand-new database and seals it to this
  /// device at epoch 0. Throws [StateError] if the roster already carries a
  /// wrap (another device founded it — pair instead).
  Future<void> found({required String label}) async {
    if (!await isUnfounded) {
      throw StateError(
        'This database already has a group key. Pair this device instead of '
        'founding a new group.',
      );
    }
    final me = await _identity.publicKey;
    final groupKey = _randomKey();
    await _writeWrap(
      publicKey: me,
      deviceId: _identity.deviceId,
      label: label,
      groupKey: groupKey,
      epoch: 0,
    );
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
  /// the key, and admits this physical device to the roster as [label].
  ///
  /// Returns `false` when the roster holds no wrap for [recovery] yet (rows
  /// may still be syncing in — retry after more sync). Throws [StateError]
  /// when [recovery]'s roster entry has been revoked: a withdrawn phrase must
  /// not regain access.
  Future<bool> adoptVia(Identity recovery, {required String label}) async {
    final rows = await _collection.all();
    final recoveryId = recovery.deviceId;
    if (_revokedIds(rows).contains(recoveryId)) {
      throw StateError(
        'This recovery phrase has been revoked and can no longer restore '
        'access.',
      );
    }
    final wraps = rows
        .whereType<WrappedGroupKey>()
        .where((w) => w.deviceId == recoveryId)
        .toList()
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
    final rows = await _collection.all();
    if (!rows.whereType<DeviceRecord>().any((d) => d.deviceId == deviceId)) {
      throw StateError('No device "$deviceId" in the roster.');
    }
    final revoked = _revokedIds(rows)..add(deviceId);
    await _rotateExcluding(revoked, rows, newlyRevoked: deviceId);
    return _groupKey!;
  }

  /// Changes the label on [deviceId]'s roster record.
  Future<void> rename(String deviceId, String label) async {
    final rows = await _collection.all();
    DeviceRecord? record;
    for (final r in rows.whereType<DeviceRecord>()) {
      if (r.deviceId == deviceId) record = r;
    }
    if (record == null) {
      throw StateError('No device "$deviceId" in the roster.');
    }
    await _collection.put(record.copyWith(label: label));
  }

  /// Every device id that is revoked, whether by a [KeyRotation] record or a
  /// [DeviceRecord] flag.
  Set<String> _revokedIds(List<DeviceRosterEntry> rows) {
    final out = <String>{};
    for (final r in rows.whereType<KeyRotation>()) {
      if (r.revokedDeviceId.isNotEmpty) out.add(r.revokedDeviceId);
    }
    for (final d in rows.whereType<DeviceRecord>()) {
      if (d.revoked) out.add(d.deviceId);
    }
    return out;
  }

  /// True when this device should be the one to re-rotate: the lowest device id
  /// among the non-revoked devices.
  bool _isElectedRotator(List<DeviceRosterEntry> rows, Set<String> revoked) {
    final active = rows
        .whereType<DeviceRecord>()
        .map((d) => d.deviceId)
        .where((id) => !revoked.contains(id))
        .toList()
      ..sort();
    return active.isNotEmpty && active.first == _identity.deviceId;
  }

  /// Rotates to `_epoch + 1`: fresh key, one wrap per non-revoked device, one
  /// [KeyRotation] record, and the [DeviceRecord] flag for [newlyRevoked].
  Future<void> _rotateExcluding(
    Set<String> revoked,
    List<DeviceRosterEntry> rows, {
    String? newlyRevoked,
  }) async {
    final nextEpoch = _epoch + 1;
    final newKey = _randomKey();
    final devices = rows.whereType<DeviceRecord>().toList();

    for (final device in devices) {
      if (revoked.contains(device.deviceId)) continue;
      final wrapped = await _identity.wrapFor(
        DevicePublicKey.fromBytes(device.publicKey),
        newKey,
      );
      await _collection.put(WrappedGroupKey(
        deviceId: device.deviceId,
        keyEpoch: nextEpoch,
        wrappedBytes: wrapped.toBytes(),
      ));
    }
    await _collection.put(KeyRotation(
      keyEpoch: nextEpoch,
      byDeviceId: _identity.deviceId,
      revokedDeviceId: newlyRevoked ?? '',
      keyDigest: _digest8(newKey),
    ));
    if (newlyRevoked != null) {
      final record = devices.firstWhere((d) => d.deviceId == newlyRevoked);
      await _collection.put(record.copyWith(revoked: true));
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
  }) async {
    final wrapped = await _identity.wrapFor(publicKey, groupKey);
    await _collection.put(WrappedGroupKey(
      deviceId: deviceId,
      keyEpoch: epoch,
      wrappedBytes: wrapped.toBytes(),
    ));
    await _collection.put(DeviceRecord(
      deviceId: deviceId,
      publicKey: publicKey.toBytes(),
      label: label,
      pairedAt: DateTime.now().toUtc(),
    ));
  }

  static List<int> _randomKey() {
    final rng = Random.secure();
    return List<int>.generate(32, (_) => rng.nextInt(256));
  }
}
