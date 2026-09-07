// Resident-memory benchmark for the storage engine.
//
// Writes N single-field documents through an engine, reads a random 1% sample
// back, and records resident set size (RSS) at checkpoints. The disk-backed
// `SqliteCrdtTable` is bounded by its page cache; `MapCrdtTable` keeps every
// record in RAM and is the contrast.
//
// Usage:
//   dart run benchmark/memory_benchmark.dart [--engine=sqlite|map]
//                                            [--n=100000] [--out=<file>]
//
// The line `WRITE_GROWTH_KB=<n>` on stdout — resident set size after all writes
// minus resident set size right after opening the engine, floored at 0 — is
// what `test/memory_bounds_test.dart` parses. It isolates the cost of holding
// the dataset from the fixed VM/JIT baseline, which `ProcessInfo.maxRss` does
// not (its transient JIT peak dwarfs the workload).
import 'dart:io';
import 'dart:math';

import 'package:conclave_core/engine.dart';

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  final engineName = opts['engine'] ?? 'sqlite';
  final n = int.parse(opts['n'] ?? '100000');
  final outPath = opts['out'];

  final tmp = Directory.systemTemp.createTempSync('conclave_bench');
  final CrdtTable table = switch (engineName) {
    'map' => MapCrdtTable('bench'),
    'sqlite' => SqliteCrdtTable('${tmp.path}/bench.sqlite'),
    _ => throw ArgumentError('unknown --engine=$engineName'),
  };
  await table.init();

  final checkpoints = <String, int>{};
  void mark(String label) => checkpoints[label] = ProcessInfo.currentRss;

  mark('after open');

  final writeSw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    await table.put('bench', _key(i), {'v': 'document number $i payload'});
    if (i == n ~/ 4) mark('25% written');
    if (i == n ~/ 2) mark('50% written');
    if (i == 3 * n ~/ 4) mark('75% written');
  }
  writeSw.stop();
  mark('100% written');

  final rng = Random(42);
  final sampleSize = max(1, n ~/ 100);
  var hits = 0;
  final readSw = Stopwatch()..start();
  for (var s = 0; s < sampleSize; s++) {
    if (await table.value('bench', _key(rng.nextInt(n))) != null) hits++;
  }
  readSw.stop();
  mark('after 1% read');

  await table.close();
  tmp.deleteSync(recursive: true);

  final growthKb = max(
    0,
    (checkpoints['100% written']! - checkpoints['after open']!) ~/ 1024,
  );

  final report = _report(
    engine: engineName,
    n: n,
    growthKb: growthKb,
    hits: hits,
    sampleSize: sampleSize,
    writeMs: writeSw.elapsedMilliseconds,
    readMs: readSw.elapsedMilliseconds,
    checkpoints: checkpoints,
  );
  stdout.write(report);
  stdout.writeln('WRITE_GROWTH_KB=$growthKb');

  if (outPath != null) {
    File(outPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(report);
    stdout.writeln('wrote $outPath');
  }
}

String _key(int i) => 'k${i.toString().padLeft(9, '0')}';

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (final arg in args) {
    final m = RegExp(r'^--([a-z]+)=(.*)$').firstMatch(arg);
    if (m == null) throw ArgumentError('bad argument: $arg');
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

String _report({
  required String engine,
  required int n,
  required int growthKb,
  required int hits,
  required int sampleSize,
  required int writeMs,
  required int readMs,
  required Map<String, int> checkpoints,
}) {
  String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1).padLeft(8);
  final buf = StringBuffer()
    ..writeln('conclave storage-engine memory benchmark')
    ..writeln('date        : ${DateTime.now().toUtc().toIso8601String()}')
    ..writeln('engine      : $engine')
    ..writeln('documents   : $n (one single-field record each)')
    ..writeln('platform    : ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}')
    ..writeln('dart        : ${Platform.version.split(' ').first}')
    ..writeln('')
    ..writeln('checkpoint            resident MB')
    ..writeln('-------------------------------------');
  for (final entry in checkpoints.entries) {
    buf.writeln('${entry.key.padRight(22)}${mb(entry.value)}');
  }
  buf
    ..writeln('-------------------------------------')
    ..writeln('growth over the write workload   '
        '${(growthKb / 1024).toStringAsFixed(1)} MB')
    ..writeln('  (resident set after all writes minus resident set after open;')
    ..writeln(
        '   the disk-backed engine holds this flat, MapCrdtTable does not)')
    ..writeln('')
    ..writeln('read sample  : $hits/$sampleSize live')
    ..writeln('write time   : $writeMs ms '
        '(${(writeMs / n * 1000).round()} us/doc)')
    ..writeln('read time    : $readMs ms');
  return buf.toString();
}
