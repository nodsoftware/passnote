# Shopping List — Provider

A minimal [Conclave](../../) example using
[`provider`](https://pub.dev/packages/provider) for state management.

It wires the collection to the UI with `CollectionNotifier<Item>` (a
`ChangeNotifier` from `conclave_flutter`) exposed via `ChangeNotifierProvider`,
and reads it with `context.watch`.

## Run

```sh
flutter run
```

## Try live sync (two devices on the same Wi-Fi)

1. Run the app on two devices/simulators on the same local network.
2. Both use the same hard-coded demo passphrase, so they automatically join the
   same encrypted room and discover each other over mDNS.
3. Add an item on one device — it appears on the other within a moment.
4. Toggle or delete items on either side and watch them stay in sync.

## Try offline convergence

1. Disconnect one device from Wi-Fi.
2. Edit the list on both devices independently.
3. Reconnect. The two lists merge automatically — concurrent edits to different
   items both survive; concurrent edits to the same item resolve to a single
   deterministic winner on both devices.

> The demo uses a fixed passphrase for convenience. A real app would call
> `conclave.generatePassphrase()` on the first device and have the user enter
> those words on the second to pair.
