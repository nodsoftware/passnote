import 'package:conclave_flutter/conclave_flutter.dart';

part 'item.g.dart';

/// Shared shopping-list item model for the Conclave examples.
///
/// The codec, document id, and CRDT schema are generated from the annotations
/// by `package:conclave_generator` — run `dart run build_runner build` after
/// changing the fields.
@Document()
class Item {
  const Item({required this.id, required this.name, this.done = false});

  /// Stable document identifier.
  @DocumentId()
  final String id;

  /// Display name, e.g. "Milk".
  final String name;

  /// Whether the item has been ticked off.
  final bool done;

  Item copyWith({String? name, bool? done}) => Item(
        id: id,
        name: name ?? this.name,
        done: done ?? this.done,
      );

  /// The generated codec: `toMap` / `fromMap` over the fields above, with
  /// [id] as the document id.
  static final Codec<Item> codec = _$ItemCodec;
}
