// The annotated model below is the input; `dart run build_runner build`
// writes the codec, the id extractor, and the per-field CRDT schema into the
// part file. See the package README for the generated names.
//
// ```dart
// import 'package:passnote/passnote.dart';
//
// part 'todo.g.dart';
//
// @Document()
// class Todo {
//   Todo({required this.id, required this.title, this.votes = 0});
//
//   @DocumentId()
//   final String id;
//
//   final String title;
//
//   @Crdt(PnCounter())
//   final int votes;
// }
//
// final todos = database.collection<Todo>('todos', _$TodoCodec,
//     mergeStrategy: _$TodoMergeStrategy);
// ```
void main() {}
