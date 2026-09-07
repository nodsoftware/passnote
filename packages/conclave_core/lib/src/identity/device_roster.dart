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

/// One row of the device roster. Every row is a [DeviceRecord] or a
/// [WrappedGroupKey].
sealed class DeviceRosterEntry {
  const DeviceRosterEntry();

  /// The stable document id for this row inside [kDeviceCollection].
  String get documentId;
}

/// A paired device: its public identity plus human-facing metadata.
final class DeviceRecord extends DeviceRosterEntry {
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
    final other =>
      throw FormatException('unknown device roster row kind: $other'),
  },
);

/// Orchestrates the reserved roster collection: resolves this device's group-key
/// state on open, and provides the founding / admit / revoke write paths.
///
/// Not exported. [Database] owns one when an [Identity] is configured.
class DeviceRoster {
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

    DeviceRecord? myRecord;
    for (final r in rows.whereType<DeviceRecord>()) {
      if (r.deviceId == myId) myRecord = r;
    }
    if (myRecord != null && myRecord.revoked) {
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

  /// Marks [deviceId] revoked in the roster. Cryptographic exclusion (a key
  /// rotation) is a later, separate step.
  Future<void> revoke(String deviceId) async {
    final rows = await _collection.all();
    DeviceRecord? record;
    for (final r in rows.whereType<DeviceRecord>()) {
      if (r.deviceId == deviceId) record = r;
    }
    if (record == null) {
      throw StateError('No device "$deviceId" in the roster.');
    }
    await _collection.put(record.copyWith(revoked: true));
    if (deviceId == _identity.deviceId) {
      _groupKey = null;
      _state = DeviceState.revoked;
    }
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
