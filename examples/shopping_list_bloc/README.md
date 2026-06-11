# Shopping List — BLoC

A minimal [Conclave](../../) example using
[`flutter_bloc`](https://pub.dev/packages/flutter_bloc) for state management.

`ShoppingCubit` subscribes to `Collection<Item>.watch()` and emits the current
`List<Item>` as its state; the UI rebuilds with `BlocBuilder`. Mutations are
written straight through to the collection, and the resulting watch event drives
the next state.

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
