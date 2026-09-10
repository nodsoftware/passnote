/// The conflict-resolution rule for a single field of a document.
///
/// A [MergeStrategy] assigns one [CrdtType] to each field path it produces. The
/// engine stores the type alongside the field's CRDT record and, when two peers
/// hold different values for that record, merges them according to the type:
///
/// - [LwwRegister] — last-write-wins by Hybrid Logical Clock. The default, and
///   the behaviour of every field before per-field types existed.
/// - [OrSet] — an observed-remove set: concurrent adds and removes both take
///   effect, with an add winning over a remove that did not observe it.
/// - [PnCounter] — a positive/negative counter whose value is the sum of every
///   peer's deltas, so concurrent increments all count.
///
/// The hierarchy is [sealed] so a later sequence or text CRDT can be added
/// without changing the [MergeStrategy] interface.
///
/// The merge algorithms for [OrSet] and [PnCounter] are not wired yet; today
/// every type merges last-write-wins. The type is still recorded on write so the
/// dispatch can be added without a data migration.
sealed class CrdtType {
  /// Const base constructor for the sealed hierarchy.
  const CrdtType();

  /// A stable short identifier persisted in the engine's `crdt_type` column.
  ///
  /// Stable across releases: it is written to disk. See [crdtTypeFromTag] for
  /// the inverse.
  String get tag;

  @override
  bool operator ==(Object other) => other.runtimeType == runtimeType;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'CrdtType($tag)';
}

/// Last-write-wins register: the field with the higher Hybrid Logical Clock
/// wins a merge and the other value is discarded.
///
/// This is the default for any field a [MergeStrategy] does not assign another
/// type, and it matches the behaviour of every field before per-field types.
final class LwwRegister extends CrdtType {
  /// Creates a last-write-wins register type.
  const LwwRegister();

  @override
  String get tag => 'lww';
}

/// Observed-remove set: concurrent adds and removes of different elements both
/// survive a merge, and an add wins over a concurrent remove that did not
/// observe it.
///
/// The merge algorithm lands in a later task; declaring the type now lets the
/// engine record it per field.
final class OrSet extends CrdtType {
  /// Creates an observed-remove set type.
  const OrSet();

  @override
  String get tag => 'or_set';
}

/// Positive/negative counter: the value is the sum of every peer's signed
/// deltas, so concurrent increments on different devices all count.
///
/// The merge algorithm lands in a later task; declaring the type now lets the
/// engine record it per field.
final class PnCounter extends CrdtType {
  /// Creates a positive/negative counter type.
  const PnCounter();

  @override
  String get tag => 'pn_counter';
}

/// Resolves a persisted [CrdtType.tag] back to a [CrdtType].
///
/// An unrecognised or `null` tag resolves to [LwwRegister], so a record written
/// before per-field types (or by a peer that does not send the tag) merges
/// last-write-wins as it always did.
CrdtType crdtTypeFromTag(String? tag) => switch (tag) {
      'or_set' => const OrSet(),
      'pn_counter' => const PnCounter(),
      _ => const LwwRegister(),
    };
