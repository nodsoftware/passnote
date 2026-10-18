# Start here

Passnote lets a small group of devices share a live dataset: a shopping list,
a household inventory, a team logbook. Every device keeps a full copy, works
offline, and syncs directly with the others. There is no server and no
account, and everything is encrypted end to end.

Two terms this site uses a lot:

- **Local-first** means each device owns a complete, always-usable copy of the
  data; the network only keeps copies in step.
- A **CRDT** (conflict-free replicated data type) is a data structure that
  devices can edit independently and still merge to the same result, in any
  order, without coordination.

## Is it a fit?

A good fit when you want:

- Shared data for a household or a small team, on their own devices.
- Offline-first behaviour with automatic merging on reconnect.
- Privacy by construction: no third party can read the data, because no third
  party ever has it.
- Nothing to deploy, nothing to pay for, nothing to breach centrally.

Not a fit when you need:

- A central source of truth, server-side logic, or access from thousands of
  users.
- Data too large for every device to hold in full.
- Fields where merging is wrong and a human must resolve conflicts by hand.

## Four nouns

| Noun | What it is |
| --- | --- |
| `Passnote` | The app-level handle. One per app; owns the transport. |
| `Database` | One shared, encrypted dataset, unlocked by a passphrase. |
| `Collection<T>` | A typed set of documents inside a database. |
| Document | One record of your model type `T`, identified by a stable id. |

## Where next

- [Tutorial](tutorial.md): from an empty Flutter app to two devices syncing,
  in eight short steps.
- [Concepts](../concepts/data-model.md): how the data model, the clocks, the
  sync protocol, and the device identity work.
- [Security](../security.md): what is protected, and the boundaries.
