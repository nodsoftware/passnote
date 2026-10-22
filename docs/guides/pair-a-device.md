# Pair a device

On any device that already has the data, create a one-time code and show it:

```dart
final code = await passnote.startPairing('home', joinerLabel: 'new phone');
// code.display => "123 456 789"
```

On the new device, enter the code:

```dart
final db = await passnote.pairWith('home', PairingCode.parse(input));
// db.deviceState == DeviceState.ready
```

That is the whole flow. The new device receives the keys, syncs, and appears
in `passnote.devices('home')` on every member.

## What the code does

The nine digits are not a password for the data; they authenticate one
exchange. Both devices run a [PAKE](../concepts/glossary.md#pake) (SPAKE2)
that proves each holds the same code without revealing it, and derives a
private channel. Over that channel the sponsor admits the joiner's public key
to the device [roster](../concepts/glossary.md#roster) and seals the
[group key](../concepts/glossary.md#group-key) to it.

- A wrong code fails visibly on both sides (`PairingRejected`).
- Each device gets three tries at a code, and the sponsor withdraws the code
  after twenty failed tries in total. Every try is one online guess at a
  one-in-a-billion code.
- The joiner adopts the sponsor's roster trust state, so the first roster it
  syncs is judged against the founder and members the sponsor vouched for.
  A 1.1 joiner refuses a sponsor that sends none (one running Passnote 1.0).
- Anyone on the network can disturb a pairing (by spending its tries, or by
  answering in the sponsor's place), but cannot complete it without the
  code. If a join is refused for no visible reason, start a new code.
- An eavesdropper who never saw the code learns nothing and cannot brute-force
  offline.
- The code is single-use; `startPairing` again for the next device, and
  `cancelPairing()` if the user closes the dialog.

Both devices must be reachable over the transport (same network for
`LanTransport`). The joiner waits up to a short timeout for the sponsor
(`PairingTimeout` otherwise).

## If the new device already opened the database

A device that called `openDatabase` while no peer was reachable has founded
its own rival group (see [identity](../concepts/identity.md)): it is
`DeviceState.ready`, its data is encrypted, and none of it belongs to the
group you want to join. `pairWith` also refuses while that database is open
locally. The way out, on the mistaken device only:

```dart
await passnote.forget('home');       // drops its key and roster trust pins
// Delete its local files: with the Flutter defaults they live under
// <application support>/passnote/<databaseId>/.
final db = await passnote.pairWith('home', PairingCode.parse(code));
```

Anything written into the rival group stays in the deleted files and never
reaches the real group — export it first if it matters. Avoid the situation
by founding explicitly on one device and joining every other device by code,
never by retyping the passphrase.
