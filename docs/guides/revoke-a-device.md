# Revoke a device

From any remaining device:

```dart
final devices = await passnote.devices('home');
final lost = devices.singleWhere((d) => d.label == 'old phone');
await passnote.revokeDevice('home', lost.id);
```

The lost device is out: everything written from now on uses a key it will
never receive.

## What happens underneath

Revocation rotates the [group key](../concepts/glossary.md#group-key): a fresh
key is generated at the next [key epoch](../concepts/glossary.md#key-epoch),
sealed to every remaining device, and the local store is re-encrypted. Peers
adopt the new key as the [roster](../concepts/glossary.md#roster) syncs, and
their per-connection [ratchets](../concepts/glossary.md#ratchet) restart on
the new key.

## What the revoked device sees

- Its own copy of the data as it was. Nothing can delete a copy a device
  already holds; revocation protects the future, not the past.
- The roster (it still holds the roster key), including the fact that it was
  revoked, so its UI can say so (`DeviceState.revoked`).
- Nothing else: new user-data frames fail authentication on it, and other
  devices ignore its data frames.

## Why there is no server

There is no account to disable, so removal is cryptographic: rotate the key
away from the device. Two devices revoking different peers while offline
converge on their own; the surviving device with the lowest id performs one
final rotation that excludes both.
