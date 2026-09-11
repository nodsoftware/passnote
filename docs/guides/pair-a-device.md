# Pair a device

On any device that already has the data, create a one-time code and show it:

```dart
final code = await conclave.startPairing('home', joinerLabel: 'new phone');
// code.display => "123 456 789"
```

On the new device, enter the code:

```dart
final db = await conclave.pairWith('home', PairingCode.parse(input));
// db.deviceState == DeviceState.ready
```

That is the whole flow. The new device receives the keys, syncs, and appears
in `conclave.devices('home')` on every member.

## What the code does

The nine digits are not a password for the data; they authenticate one
exchange. Both devices run a [PAKE](../concepts/glossary.md#pake) (SPAKE2)
that proves each holds the same code without revealing it, and derives a
private channel. Over that channel the sponsor admits the joiner's public key
to the device [roster](../concepts/glossary.md#roster) and seals the
[group key](../concepts/glossary.md#group-key) to it.

- A wrong code fails visibly on both sides (`PairingRejected`).
- The sponsor disarms the code after three failed attempts.
- An eavesdropper who never saw the code learns nothing and cannot brute-force
  offline.
- The code is single-use; `startPairing` again for the next device, and
  `cancelPairing()` if the user closes the dialog.

Both devices must be reachable over the transport (same network for
`LanTransport`). The joiner waits up to a short timeout for the sponsor
(`PairingTimeout` otherwise).
