import 'dart:async';

import 'package:conclave/conclave.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'item.dart';

/// A [Cubit] that mirrors a Conclave [Collection] of [Item]s.
///
/// It subscribes to [Collection.watch] and emits the current list — sorted by
/// name — on every local or synced change. Mutations are written straight
/// through to the collection; the resulting watch event updates the state.
class ShoppingCubit extends Cubit<List<Item>> {
  ShoppingCubit(this._items) : super(const []) {
    _subscription = _items.watch().listen((items) {
      final sorted = [...items]..sort((a, b) => a.name.compareTo(b.name));
      emit(sorted);
    });
  }

  final Collection<Item> _items;
  late final StreamSubscription<List<Item>> _subscription;

  Future<void> add(Item item) => _items.put(item);

  Future<void> toggle(Item item) => _items.put(item.copyWith(done: !item.done));

  Future<void> remove(String id) => _items.delete(id);

  @override
  Future<void> close() {
    _subscription.cancel();
    return super.close();
  }
}
