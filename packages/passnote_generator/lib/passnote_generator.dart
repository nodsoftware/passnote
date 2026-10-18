/// Code generator for Passnote document models.
///
/// Annotate a model with `@Document()` (see `package:passnote`), add
/// `part '<file>.g.dart';`, and run `dart run build_runner build`. One
/// annotation yields the codec, the document-id extractor, and the per-field
/// CRDT schema — no hand-written maps, and the three can never drift apart.
library;

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/document_generator.dart';

export 'src/document_generator.dart' show DocumentGenerator;

/// The builder entry point wired up by `build.yaml`. Emits into the shared
/// `.g.dart` part file, so it composes with other `source_gen` builders.
Builder passnoteGenerator(BuilderOptions options) =>
    SharedPartBuilder([DocumentGenerator()], 'passnote');
