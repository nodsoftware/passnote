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
- Nothing else: user data travels only inside sessions with non-revoked
  members, and its signature no longer opens one. Anything it sends outside a
  session that is not a roster row is ignored, and its roster rows no longer
  count.

The roster key is derived from the passphrase and does not change on
revocation, so the revoked device can still find the group on the network,
see who is in the roster, and send frames that others must spend effort
refusing. If the device is in hostile hands, also
[rotate the passphrase](rotate-the-passphrase.md) on the remaining devices:
it moves the room and the roster to a key the revoked device does not hold.

Devices the revoked one had paired keep their membership: the revoking
device re-signs their roster records as part of the revocation.

## Why there is no server

There is no account to disable, so removal is cryptographic: rotate the key
away from the device. Two devices revoking different peers while offline
converge on their own; the surviving device with the lowest id performs one
final rotation that excludes both.
