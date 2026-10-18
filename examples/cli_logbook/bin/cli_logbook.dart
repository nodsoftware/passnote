// A two-device encrypted logbook in a terminal — the pure-Dart setup story.
//
//   dart run cli_logbook create           # first device: founds, prints words
//   dart run cli_logbook pair             # first device: prints a one-time code
//   dart run cli_logbook join 123456789   # second device: joins with the code
//   dart run cli_logbook add "note"       # either device
//   dart run cli_logbook star <id>        # counter: stars from both count
//   dart run cli_logbook list | watch
//
// State lives under .logbook/ (override with LOGBOOK_DIR).
import 'dart:io';

import 'package:cli_logbook/logbook.dart';
import 'package:passnote/passnote.dart';

const appId = 'cli-logbook';
const dbId = 'book';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    return;
  }
  installLogbookDefaults(
    Directory(Platform.environment['LOGBOOK_DIR'] ?? '.logbook'),
  );
  final passnote =
      await Passnote.builder(appId: appId, salt: '$appId:v1').open();
  passnote.events.listen((event) {
    if (event is PeerDiscoveryUnavailable) {
      stderr.writeln('discovery unavailable: ${event.reason}\n'
          'see docs/guides/set-up-platforms.md');
    }
  });

  try {
    switch (args.first) {
      case 'create':
        await _create(passnote);
      case 'join':
        await _join(passnote, args);
      case 'pair':
        await _pair(passnote);
      case 'add':
        await _add(passnote, args);
      case 'star':
        await _star(passnote, args);
      case 'list':
        await _list(passnote);
      case 'watch':
        await _watch(passnote);
      default:
        _usage();
    }
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  } on PairingTimeout {
    // Both pairing failures are ordinary outcomes, not crashes: the code is
    // one-shot, and the devices have to reach each other over the transport.
    stderr.writeln('the other device did not answer. Check that both are on '
        'the same network, then run `logbook pair` again for a fresh code.');
    exitCode = 1;
  } on PairingRejected catch (e) {
    stderr.writeln('pairing refused: ${e.reason}. Run `logbook pair` again '
        'for a fresh code.');
    exitCode = 1;
  } finally {
    await passnote.close();
  }
}

void _usage() => stdout.writeln('usage: logbook create | pair | join <code> | '
    'add <text> | star <id> | list | watch');

/// Founds the logbook on this device and prints the passphrase once.
///
/// Founding is explicit here rather than left to openDatabase's first-run
/// auto-found, which only fires when no peer is connected at that instant —
/// an explicit foundGroup makes "this is the first device" a decision, not a
/// race.
Future<void> _create(Passnote passnote) async {
  final words = passnote.generatePassphrase().join(' ');
  final db = await passnote.openDatabase(dbId, passphrase: words);
  if (db.deviceState != DeviceState.ready) await db.foundGroup();
  stdout.writeln('logbook created. Passphrase (write it down, shown once):');
  stdout.writeln('  $words');
  stdout.writeln('add devices with: logbook pair');
}

/// Reopens the already-created logbook with the key held in the KeyStore.
Future<Database> _open(Passnote passnote) async {
  try {
    return await passnote.reopenDatabase(dbId);
  } on StateError {
    throw StateError('no logbook here yet: run `logbook create` on the first '
        'device or `logbook join <code>` on a new one');
  }
}

Collection<Entry> _entries(Database db) =>
    // The generated merge strategy is passed explicitly: without it the
    // collection would default to whole-document last-write-wins and
    // `star` (a counter increment) would throw.
    db.collection<Entry>('entries', entryCodec, merge: entryMerge);

Future<void> _pair(Passnote passnote) async {
  await _open(passnote);
  final before = (await passnote.devices(dbId)).length;
  final code = await passnote.startPairing(dbId);
  stdout.writeln('on the new device, run: logbook join ${code.digits}');
  stdout.writeln('waiting (ctrl-c to cancel)...');
  while ((await passnote.devices(dbId)).length == before) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  stdout.writeln('device paired.');
  // Let the freshly sealed group key reach the joiner before exiting.
  await passnote.forceSync();
  await Future<void>.delayed(const Duration(seconds: 1));
}

Future<void> _join(Passnote passnote, List<String> args) async {
  if (args.length < 2) return _usage();
  final db = await passnote.pairWith(dbId, PairingCode.parse(args[1]));
  stdout.writeln('joined. Current entries:');
  // The sponsor sends what it already holds once this device opens the
  // collection; give those frames a moment before printing.
  final entries = _entries(db);
  await _settle(passnote);
  for (final entry in await entries.all()) {
    stdout.writeln('  ${entry.id}  ${'*' * entry.stars.toInt()}  '
        '${entry.text}');
  }
}

Future<void> _add(Passnote passnote, List<String> args) async {
  if (args.length < 2) return _usage();
  final db = await _open(passnote);
  final entry = Entry(id: newId(), text: args.skip(1).join(' '));
  await _entries(db).put(entry);
  stdout.writeln('added ${entry.id}');
  await _settle(passnote);
}

Future<void> _star(Passnote passnote, List<String> args) async {
  if (args.length < 2) return _usage();
  final db = await _open(passnote);
  await _entries(db).increment(args[1], 'stars');
  stdout.writeln('starred ${args[1]}');
  await _settle(passnote);
}

Future<void> _list(Passnote passnote) async {
  final db = await _open(passnote);
  // Give discovery a moment so freshly synced entries are included.
  await _settle(passnote);
  final all = await _entries(db).all();
  if (all.isEmpty) stdout.writeln('(empty)');
  for (final entry in all) {
    stdout.writeln('  ${entry.id}  ${'*' * entry.stars.toInt()}  '
        '${entry.text}');
  }
}

Future<void> _watch(Passnote passnote) async {
  final db = await _open(passnote);
  stdout.writeln('watching (ctrl-c to stop)...');
  final sub = _entries(db).watch().listen((all) {
    stdout.writeln('--- ${all.length} entries');
    for (final entry in all) {
      stdout.writeln('  ${entry.id}  ${'*' * entry.stars.toInt()}  '
          '${entry.text}');
    }
  });
  await ProcessSignal.sigint.watch().first;
  await sub.cancel();
}

/// Lets discovery find peers and in-flight frames land before the process
/// exits (a long-running app needs none of this).
Future<void> _settle(Passnote passnote) async {
  await Future<void>.delayed(const Duration(seconds: 2));
  await passnote.forceSync();
  await Future<void>.delayed(const Duration(milliseconds: 500));
}
