import 'dart:convert';

import 'lww_register.dart';

/// State and merge rules for an [OrSet] field — an observed-remove set. A
/// concurrent add and remove of *different* elements both take effect; for the
/// *same* element, an add wins over a remove that did not observe it.
///
/// The stored representation tags every add with an id unique to the replica
/// that made it:
///
/// ```json
/// {"__t": "or_set", "adds": {"<node>#7": "milk"}, "tombstones": ["<node>#3"]}
/// ```
///
/// An element is present when it has at least one add tag that is not in
/// `tombstones`. Removing an element tombstones exactly the add tags the local
/// replica can see for it, so an add the remover never observed is untouched.

/// The `crdt_type` tag for an OR-Set, persisted on the row and on the wire.
const String orSetTag = 'or_set';

/// An empty set state.
Map<String, Object?> orEmpty() => {
      crdtTypeKey: orSetTag,
      'adds': <String, Object?>{},
      'tombstones': <String>[],
    };

/// The logical value of [state]: the live elements, ordered by their JSON
/// encoding so two converged replicas produce an identical list.
List<Object?> orResolve(Object? state) {
  final s = _normalise(state);
  final tombstones = (s['tombstones'] as List).cast<String>().toSet();
  final live = <Object?>[];
  for (final entry in (s['adds'] as Map).entries) {
    if (!tombstones.contains(entry.key)) live.add(entry.value);
  }
  // De-duplicate equal elements (two adds of the same value), then sort.
  final unique = <Object?>[];
  for (final element in live) {
    if (!unique.any((e) => crdtValueEquals(e, element))) unique.add(element);
  }
  unique.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
  return unique;
}

/// Folds a [desired] membership list into [state]: elements in [desired] that
/// are not currently live are added with a fresh tag from [mintTag]; currently
/// live elements absent from [desired] have their visible tags tombstoned.
///
/// The result is in the same canonical shape [orMerge] produces (tombstoned
/// tags pruned from `adds`, `tombstones` sorted), so two equal set states are
/// structurally equal under [crdtValueEquals].
Map<String, Object?> orApplyDesired(
  Object? state,
  Iterable<Object?> desired,
  String Function() mintTag,
) {
  final s = _normalise(state);
  final adds = Map<String, Object?>.from(s['adds'] as Map);
  final tombstoneSet = (s['tombstones'] as List).cast<String>().toSet();

  final current = orResolve(s);
  final wanted = <Object?>[];
  for (final element in desired) {
    if (!wanted.any((e) => crdtValueEquals(e, element))) wanted.add(element);
  }

  for (final element in wanted) {
    if (!current.any((e) => crdtValueEquals(e, element))) {
      adds[mintTag()] = element;
    }
  }
  for (final element in current) {
    if (!wanted.any((e) => crdtValueEquals(e, element))) {
      for (final entry in adds.entries) {
        if (!tombstoneSet.contains(entry.key) &&
            crdtValueEquals(entry.value, element)) {
          tombstoneSet.add(entry.key);
        }
      }
    }
  }
  adds.removeWhere((tag, _) => tombstoneSet.contains(tag));

  return {
    crdtTypeKey: orSetTag,
    'adds': adds,
    'tombstones': tombstoneSet.toList()..sort(),
  };
}

/// Merges two set states: the union of their add tags and of their tombstones.
/// Tombstoned add tags are dropped from `adds` (the tombstone is kept), so
/// `adds` stays bounded by the live set size.
Map<String, Object?> orMerge(Object? a, Object? b) {
  final sa = _normalise(a);
  final sb = _normalise(b);

  final tombstones = <String>{
    ...(sa['tombstones'] as List).cast<String>(),
    ...(sb['tombstones'] as List).cast<String>(),
  };
  final adds = <String, Object?>{};
  for (final source in [sa['adds'] as Map, sb['adds'] as Map]) {
    for (final entry in source.entries) {
      if (!tombstones.contains(entry.key)) {
        adds[entry.key as String] = entry.value;
      }
    }
  }

  return {
    crdtTypeKey: orSetTag,
    'adds': adds,
    'tombstones': tombstones.toList()..sort(),
  };
}

Map<String, Object?> _normalise(Object? state) {
  if (state is Map && state[crdtTypeKey] == orSetTag) {
    return {
      crdtTypeKey: orSetTag,
      'adds': Map<String, Object?>.from((state['adds'] as Map?) ?? const {}),
      'tombstones':
          ((state['tombstones'] as List?) ?? const []).cast<String>().toList(),
    };
  }
  return orEmpty();
}
