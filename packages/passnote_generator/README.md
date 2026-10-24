# passnote_generator

Code generator for [Passnote](https://github.com/nodsoftware/passnote) document models: one annotation
yields the codec, the document id extractor, and the per-field CRDT schema —
no hand-written maps, and the three can never drift apart.

## Use

Add to a package that defines document models:

```yaml
dev_dependencies:
  build_runner: ^2.15.0
  passnote_generator: ^1.1.2
```

Annotate the model and add a `part` directive:

```dart
import 'package:passnote/passnote.dart';

part 'task.g.dart';

@Document()
class Task {
  const Task({required this.id, required this.title, this.qty = 0});

  @DocumentId()
  final String id;

  final String title; // Unannotated: merges last-write-wins.

  @Crdt(PnCounter())
  final num qty; // Concurrent increments sum.

  static final Codec<Task> codec = _$TaskCodec;
  static const MergeStrategy merge = _$TaskMergeStrategy;
}
```

Then generate:

```sh
dart run build_runner build --delete-conflicting-outputs
```

And use the generated artefacts when opening the collection:

```dart
final tasks = db.collection<Task>('tasks', Task.codec, merge: Task.merge);
```

## What the generator expects

- An unnamed constructor whose parameters (named or positional) match the
  instance fields by name. Parameter default values fill fields a stored
  document lacks.
- Exactly one `@DocumentId()` field, a non-nullable `String`.
- Field types: `String`, `int`, `double`, `num`, `bool`, their nullable
  forms, `List` of a scalar, `Map<String, scalar>`. Anything else fails the
  build with a message naming the field — write a manual `JsonCodec` for
  exotic shapes.
- A `@Crdt(PnCounter())` field is a number; a `@Crdt(OrSet())` field is a
  `List`.
