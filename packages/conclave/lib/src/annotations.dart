import 'crdt/crdt_type.dart';

/// Marks a class as a Conclave document model, so `package:conclave_generator`
/// generates its codec, document-id extractor, and per-field CRDT schema in
/// one pass — no hand-written maps, and the schema can never drift from the
/// codec.
///
/// ```dart
/// import 'package:conclave/conclave.dart';
///
/// part 'task.g.dart';
///
/// @Document()
/// class Task {
///   const Task({required this.id, required this.title, this.qty = 0});
///
///   @DocumentId()
///   final String id;
///
///   final String title; // No annotation: merges last-write-wins.
///
///   @Crdt(PnCounter())
///   final num qty;
///
///   static final Codec<Task> codec = _$TaskCodec;
///   static const MergeStrategy merge = _$TaskMergeStrategy;
/// }
/// ```
///
/// The generator reads the class's instance fields and its unnamed
/// constructor. Every serialized field must be settable through a constructor
/// parameter with the same name; a parameter default value is honoured when
/// the stored document lacks the field. Field types are limited to what the
/// engine stores natively: `String`, `int`, `double`, `num`, `bool`, their
/// nullable forms, `List` of a scalar, and `Map<String, scalar>`. Anything
/// else fails the build with a message naming the field — write a manual
/// `JsonCodec` for exotic shapes.
///
/// Generated members (in the `part` file): `_$XCodec` (a `Codec<X>`),
/// `_$XSchema` (`Map<String, CrdtType>`), and `_$XMergeStrategy` (a const
/// `SchemaMergeStrategy` over that schema).
class Document {
  /// Marks a class for codec generation.
  const Document();
}

/// Marks the one field whose value identifies the document
/// ([Codec.idOf]). Required, exactly once per [Document] class, on a
/// non-nullable `String` field.
class DocumentId {
  /// Marks the document-id field.
  const DocumentId();
}

/// Assigns a [CrdtType] to the annotated field, so concurrent edits to it
/// merge by that type's rule instead of last-write-wins.
///
/// ```dart
/// @Crdt(PnCounter())
/// final num qty;      // Concurrent increments sum.
///
/// @Crdt(OrSet())
/// final List<String> tags; // Concurrent adds and removes both apply.
/// ```
///
/// A `PnCounter` field must be a number and an `OrSet` field a list.
/// Unannotated fields merge last-write-wins ([LwwRegister]) — annotating one
/// with `@Crdt(LwwRegister())` is allowed and equivalent.
class Crdt {
  /// Assigns [type] to the annotated field.
  const Crdt(this.type);

  /// The merge rule for the field.
  final CrdtType type;
}
