# Troubleshoot sync

Work top to bottom: make the state visible, then split the problem into
"peers do not find each other" versus "peers connect but data does not
move".

## First: make the state visible

`Conclave.events` narrates the peer lifecycle. Log it before anything else:

```dart
conclave.events.listen((event) => debugPrint('conclave: $event'));
```

| Event | Meaning |
| --- | --- |
| `PeerAppeared` | A peer was discovered and connected. Sync with it starts now. |
| `PeerDisappeared` | A connection closed. Reconnection is automatic. |
| `PeerIncompatible` | The peer speaks no common wire version. One of the two apps needs an update; nothing syncs until then. |
| `StoreRecovered` | A local store failed its integrity check and was rebuilt from a snapshot or from peers. The corrupt file is kept beside it. |

## No `PeerAppeared` at all

The devices do not find each other. In rough order of likelihood:

1. **Platform permissions.** The most common cause on real devices, and
   always silent. Every item in
   [Set up platform permissions](set-up-platforms.md) matters; on iOS in
   particular, an app without the multicast entitlement discovers nothing.
2. **The network blocks device-to-device traffic.** Guest Wi-Fi client
   isolation, corporate VLANs, and some mesh routers drop multicast. Put
   both devices on a phone hotspot to test: if they find each other there,
   it is the network.
3. **Not the same network.** Wi-Fi on one device, cellular on the other, or
   two different SSIDs.
4. **Emulators.** Android emulators are NATed away from each other; the iOS
   Simulator generally works but shares the Mac's network identity. Prefer
   real devices for discovery testing.
5. **Different `appId`.** Discovery is scoped by it; the two builds must
   match exactly.
6. **Different passphrase.** The discovery [room
   tag](../concepts/glossary.md#room-tag) derives from the passphrase, so a
   device that opened the database with a different passphrase advertises a
   different tag and is invisible to the group. Re-open with the right one.

`WebSocketTransport` with an explicit address bypasses discovery entirely;
it is both a workaround and a diagnostic (if it syncs, the problem was
discovery, not sync).

## Peers appear, but data does not move

- **The new device has not paired.** Opening a database with the passphrase
  is not membership: a device without a key wrap sits in
  `DeviceState.needsPairing`, syncs only the device roster, and cannot read
  user collections. Run the [pairing flow](pair-a-device.md).
- **The device was revoked.** A revoked device keeps its local copy but is
  cryptographically outside the group: nothing written after the revocation
  reaches it, in either direction.
- **Different database id.** `openDatabase('home')` and
  `openDatabase('Home')` are different datasets.
- **You are watching the wrong moment.** `watch()` emits once loaded and on
  every change; a test that reads before sync completes sees the old state.
  Wait on `watch().firstWhere(...)` with a timeout, or call
  `conclave.forceSync()` to exchange with every connected peer immediately.
- **A very fast writer.** Inbound frames are rate-limited per peer
  (`maxInboundFramesPerSecond`, default 100). Dropped frames are not lost
  data: the periodic anti-entropy exchange (default every 3 minutes) heals
  the gap. If a test needs a burst to land now, raise the limit on the
  builder.

## Exceptions worth handling

| Exception | When | What to do |
| --- | --- | --- |
| `WrongPassphraseException` | `openDatabase` with a passphrase that does not match the stored data. | Ask the user to re-enter it. |
| `WeakPassphraseException` | A non-mnemonic passphrase under a `strict` policy. | Generate one with `generatePassphrase()`, or relax the policy deliberately. |
| `PairingRejected` | The code was wrong, or the sponsor declined. Three failures end the attempt. | Start a fresh code; each guess costs a visible failure. |
| `PairingTimeout` | The two devices never met during the pairing window. | Check discovery first (above), then retry. |
| `CipherAuthError` | A frame or stored record failed authentication. Dropped, never partially applied. | Nothing; if persistent across restarts, the passphrase or key material is wrong. |

## When a store was corrupt

A `StoreRecovered` event means SQLite integrity checking failed on open. The
unreadable file was moved aside (`.corrupt-<timestamp>`), the store was
rebuilt from the latest snapshot or re-synced from peers, and the app keeps
running. There is nothing to do, but the event is worth logging: repeated
recoveries point at failing storage.

## Still stuck

Open an issue with the `events` log from both devices, the platforms
involved, and what the network is (home Wi-Fi, office, hotspot). That tuple
answers most reports.
