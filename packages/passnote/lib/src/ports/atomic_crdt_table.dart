/// An engine that can apply several writes as one: all of them land, or, if
/// the process dies or a write fails half-way, none do.
///
/// Not part of the `CrdtTable` port, so engines outside Passnote need not
/// implement it; `Collection` uses it when the engine offers it, and writes
/// record by record otherwise. `SqliteCrdtTable` implements it with one
/// SQLite transaction.
abstract interface class AtomicCrdtTable {
  /// Runs [writes] so that their effects are committed together.
  Future<void> atomically(Future<void> Function() writes);
}
