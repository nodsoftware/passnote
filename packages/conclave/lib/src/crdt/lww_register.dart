/// Shared helpers for the per-field CRDT types.
///
/// [LwwRegister] itself needs no stored state: its value is the plain value and
/// merge is the Hybrid Logical Clock comparison already performed by the
/// storage engine. This file holds the pieces the typed engine ([OrSet] and
/// [PnCounter]) share — the `__t` discriminator key and a structural equality
/// used to decide whether a merge actually changed a row.
library;

/// The key inside a typed row's stored JSON that names its CRDT type, so a
/// value read back from any engine can be interpreted without a side table.
const String crdtTypeKey = '__t';

/// Reads the [crdtTypeKey] discriminator from a stored value, or `null` when
/// the value is a plain (last-write-wins) value.
String? storedCrdtTag(Object? storedValue) {
  if (storedValue is Map && storedValue[crdtTypeKey] is String) {
    return storedValue[crdtTypeKey] as String;
  }
  return null;
}

/// Structural equality over decoded JSON (`Map`, `List`, scalars). Used to keep
/// a converged CRDT row quiescent: if a merge produces a value equal to the one
/// already stored, the engine writes nothing.
bool crdtValueEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!crdtValueEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!crdtValueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}
