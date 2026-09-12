# Rotate the passphrase

When the words have been seen by the wrong person — or written on a whiteboard
in a photo — change them:

```dart
final words = conclave.generatePassphrase();       // show these, once
await conclave.rotatePassphrase(
  'home',
  oldPassphrase: oldWords.join(' '),
  newPassphrase: words.join(' '),
);
```

The database stays open and usable throughout. Every `Collection`
handle the app is holding keeps working, because the stores are re-encrypted
in place rather than replaced.

## What actually changes

Only what the passphrase protects: the [roster](../concepts/glossary.md#roster)
and control key, and the [room tag](../concepts/glossary.md#room-tag) derived
from it. The [group key](../concepts/glossary.md#group-key) is not derived from
the passphrase, so:

- no user data is re-encrypted, however much of it there is;
- no device loses its membership;
- nothing has to sync for the rotation to be complete.

## Every device has to be rotated

The room tag moves with the passphrase, so a rotated device stops exchanging
frames with peers that still hold the old one. They are not broken — they carry
on among themselves — but they are no longer talking to the rotated device.

Two ways to bring them over, and the app should say which it means:

1. **Rotate each device** with the same two phrases. The person doing it has
   both in hand at that moment, which is the whole reason this is the simple
   path.
2. **Pair them again.** Pairing hands over whatever key the sponsor currently
   holds, so a device added after the rotation needs no words at all.

A future release may propagate a rotation to connected devices automatically.
Until then, rotation is a per-device act and should be presented as one.

## Interrupted rotations

A rotation that is killed halfway — the phone dies, the app is force-quit —
finishes itself the next time the database is opened, with or without a
passphrase:

```dart
if (await conclave.hasPendingRotation('home')) {
  // Already handled by the next open; this is only so the UI can say so.
}
```

The new key is journalled in the [key store](../reference/ports.md) before
any store is touched, so what survives a crash is always "one of these two keys
opens each store". The next `openDatabase` or `reopenDatabase` re-keys whatever
is still on the old key, promotes the new one, and clears the journal. **A
database is never left unopenable.**

If the process dies before the journal is written, nothing happened at all and
the old words still work.

## What it does not do

- It does not change the [group key](../concepts/glossary.md#group-key). To lock
  out a device, [revoke it](revoke-a-device.md) — that is a different key and a
  different act.
- It does not re-mint a [recovery phrase](recover-from-a-lost-passphrase.md).
  A phrase minted with `enableRecovery` keeps working: it is a roster entry, not
  a passphrase.
