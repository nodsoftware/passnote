# Recover access

First, the cases that need no recovery machinery:

- **Lost a device, still have another?** Nothing to recover:
  [pair](pair-a-device.md) the replacement with a code from the surviving
  device, and [revoke](revoke-a-device.md) the lost one.
- **Forgot the passphrase but devices still run?** The stored keys keep
  working (`reopenDatabase` needs no passphrase). Pair any new devices from a
  running one.

The hard case is losing every device. By default that means the data is gone;
nothing is escrowed anywhere, and for many apps that is the right promise.

## The opt-in recovery phrase

An app that wants a way back enables recovery and mints a phrase once, after
setup:

```dart
final passnote = await passnoteBuilder(appId: 'x', salt: 'x:v1')
    .recovery(enabled: true)
    .open();

final words = await passnote.enableRecovery('home');
// Show the 24 words once. Never store them.
```

The phrase's derived keypair joins the device roster as a virtual member with
its own sealed copy of the group key.

On a fresh install, with at least one peer reachable (a housemate's device,
for example):

```dart
final db = await passnote.recoverFrom(
  'home',
  enteredWords,
  passphrase: databasePassphrase,
);
```

The roster syncs from the peer, the phrase's keypair opens its sealed key, and
the new device is admitted as an ordinary member. Both the phrase and the
database passphrase are needed: the phrase replaces the lost devices, not the
passphrase.

A phrase can be withdrawn like a device: find its roster entry (labelled
`recovery phrase`) and `revokeDevice` it. A revoked phrase can never recover.
