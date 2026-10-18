#!/usr/bin/env bash
# Reproduces a user's world: a consumer package OUTSIDE this workspace runs a
# fresh `dart pub get`, which resolves the NEWEST analyzer the generator's
# constraint allows — inside the workspace the Flutter SDK pins `meta`, which
# caps analyzer several majors below what users get, so workspace CI alone
# can never catch an analyzer API break (the displayName → Class.new kind).
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

# Path-consumable copies: `resolution: workspace` only resolves inside the
# workspace, so it is stripped from the copies.
for p in passnote passnote_generator; do
  cp -R "$root/packages/$p" "$dir/$p"
  sed -i.bak '/^resolution: workspace$/d' "$dir/$p/pubspec.yaml"
done

mkdir "$dir/consumer"
cd "$dir/consumer"
cat > pubspec.yaml <<EOF
name: consumer
publish_to: none
environment:
  sdk: ^3.6.0
dependencies:
  passnote:
    path: ../passnote
dev_dependencies:
  build_runner: ^2.15.0
  passnote_generator:
    path: ../passnote_generator
# The generator names `passnote` as a hosted dependency (it is unpublished
# while this check runs pre-release); route it to the local copy.
dependency_overrides:
  passnote:
    path: ../passnote
EOF

mkdir lib
cat > lib/model.dart <<'EOF'
import 'package:passnote/passnote.dart';

part 'model.g.dart';

@Document()
class Note {
  const Note({required this.id, required this.title, this.count = 0});

  @DocumentId()
  final String id;

  final String title;

  @Crdt(PnCounter())
  final num count;
}

// Public handles for consumers outside this library.
final Codec<Note> noteCodec = _$NoteCodec;
const MergeStrategy noteMerge = _$NoteMergeStrategy;
EOF

dart pub get
resolved=$(dart pub deps --style compact 2>/dev/null | grep -Eo 'analyzer [0-9.]+' | head -1)
echo "consumer resolved: $resolved"

dart run build_runner build

grep -q '_\$NoteCodec' lib/model.g.dart
grep -q '_\$NoteMergeStrategy' lib/model.g.dart
grep -q 'PnCounter' lib/model.g.dart
echo "OK: generator built an @Document model against the freshly resolved $resolved."

# Core smoke against the same fresh resolution: open, write through the
# generated codec AND merge strategy, increment the counter, read back.
mkdir bin
cat > bin/smoke.dart <<'EOF2'
import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart';

import 'package:consumer/model.dart';

class _MemKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => _keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;
  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

class _NoopCipher implements Cipher {
  @override
  Future<List<int>> encrypt(List<int> plaintext) async => plaintext;
  @override
  Future<List<int>> decrypt(List<int> ciphertext) async => ciphertext;
}

Future<void> main() async {
  final passnote = await passnoteLowLevel(
    config: const PassnoteConfig(appId: 's', salt: 's:v1'),
    keyStore: _MemKeyStore(),
    transport: InMemoryTransport(InMemoryBus()),
    deriveKey: (_, __) async => List<int>.filled(32, 1),
    roomTag: (_) => 'room',
    cipher: (_) => _NoopCipher(),
    mnemonicGenerator: (n) => List.filled(n, 'abandon'),
    validateMnemonic: (_) => true,
    engine: (dbId, collection, _) => MapCrdtTable(collection),
  );
  final db = await passnote.openDatabase('d', passphrase: 'p');
  final notes = db.collection<Note>('notes', noteCodec, merge: noteMerge);
  await notes.put(const Note(id: 'x', title: 'hello'));
  await notes.increment('x', 'count', by: 3);
  final note = await notes.get('x');
  if (note == null || note.title != 'hello' || note.count != 3) {
    throw StateError('smoke round-trip failed');
  }
  await passnote.close();
  print('smoke ok');
}
EOF2
dart run bin/smoke.dart
echo "OK: core opened, wrote, and read against the freshly resolved set."
