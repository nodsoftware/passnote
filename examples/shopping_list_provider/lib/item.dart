/// Shared shopping-list item model for the Conclave examples.
class Item {
  const Item({required this.id, required this.name, this.done = false});

  /// Stable document identifier.
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

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'done': done};

  factory Item.fromJson(Map<String, dynamic> json) => Item(
        id: json['id'] as String,
        name: json['name'] as String,
        done: (json['done'] as bool?) ?? false,
      );
}
