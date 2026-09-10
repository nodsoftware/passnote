import 'dart:async';

import 'package:conclave/conclave.dart';
import 'package:flutter/foundation.dart';

/// A [ChangeNotifier] that mirrors the contents of a Conclave [Collection],
/// rebuilding dependent widgets whenever the collection changes — locally or
/// from a synced peer.
///
/// Wrap it in a `ChangeNotifierProvider` (or `ListenableBuilder`) and read
/// [items] in your build method:
///
/// ```dart
/// ChangeNotifierProvider(
///   create: (_) => CollectionNotifier(db.collection<Item>('items')),
///   child: Consumer<CollectionNotifier<Item>>(
///     builder: (_, notifier, __) => ListView(
///       children: [for (final item in notifier.items) ItemTile(item)],
///     ),
///   ),
/// );
/// ```
///
/// The default constructor mirrors the **whole** collection and re-decodes
/// every document on every change. For a screen that shows a filtered, sorted,
/// or paginated slice, prefer [CollectionNotifier.query], whose cost per
/// change is bounded by the query result and which only notifies when that
/// result actually changes:
///
/// ```dart
/// CollectionNotifier.query(
///   db.collection<Item>('items').query()
///       .where('done', isEqualTo: false)
///       .orderBy('createdAt', descending: true)
///       .limit(50),
/// );
/// ```
class CollectionNotifier<T> extends ChangeNotifier {
  /// Creates a notifier that subscribes to [collection] immediately and
  /// mirrors all of it. Every change decodes the whole collection; see
  /// [CollectionNotifier.query] for a bounded-cost slice.
  CollectionNotifier(Collection<T> collection) : this._(collection.watch());

  /// Creates a notifier that mirrors [query]'s result and notifies only when
  /// that result changes. Each change costs the query, not the collection.
  CollectionNotifier.query(CollectionQuery<T> query) : this._(query.watch());

  CollectionNotifier._(Stream<List<T>> source) {
    _items = [];
    _subscription = source.listen((items) {
      _items = items;
      notifyListeners();
    });
  }

  late StreamSubscription<List<T>> _subscription;
  late List<T> _items;

  /// The current live documents in the collection.
  List<T> get items => List.unmodifiable(_items);

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
