import 'dart:async';

import 'package:conclave_core/conclave_core.dart';
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
class CollectionNotifier<T> extends ChangeNotifier {
  /// Creates a notifier that subscribes to [collection] immediately.
  CollectionNotifier(this._collection) {
    _items = _collection.all;
    _subscription = _collection.watch().listen((items) {
      _items = items;
      notifyListeners();
    });
  }

  final Collection<T> _collection;
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
