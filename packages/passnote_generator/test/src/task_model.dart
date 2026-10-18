import 'package:passnote/passnote.dart';

part 'task_model.g.dart';

/// Exercises every supported field shape: the id, an untyped scalar, a bool
/// with a default, a counter, a set, a nullable scalar, and a scalar map.
@Document()
class Task {
  const Task({
    required this.id,
    required this.title,
    this.done = false,
    this.qty = 0,
    this.tags = const [],
    this.priority,
    this.scores = const {},
  });

  @DocumentId()
  final String id;

  final String title;

  final bool done;

  @Crdt(PnCounter())
  final num qty;

  @Crdt(OrSet())
  final List<String> tags;

  final int? priority;

  final Map<String, double> scores;

  static final Codec<Task> codec = _$TaskCodec;
  static const MergeStrategy merge = _$TaskMergeStrategy;
  static const Map<String, CrdtType> schema = _$TaskSchema;
}

/// A minimal positional-constructor model: the generator must pass positional
/// arguments in declaration order.
@Document()
class Note {
  const Note(this.id, this.text);

  @DocumentId()
  final String id;

  final String text;

  static final Codec<Note> codec = _$NoteCodec;
}
