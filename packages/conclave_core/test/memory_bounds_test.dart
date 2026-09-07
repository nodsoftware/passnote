@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:test/test.dart';

/// Runs `benchmark/memory_benchmark.dart` for each engine and asserts that the
/// disk-backed engine's resident memory stays flat while `MapCrdtTable`'s grows
/// with the dataset. Skipped by default (see `dart_test.yaml`); CI runs it with
/// `dart test --run-skipped -t benchmark`.
void main() {
  test(
    'SqliteCrdtTable holds resident memory flat where MapCrdtTable grows',
    () async {
      const n = 100000;
      final sqliteGrowthKb = await _writeGrowthKb('sqlite', n);
      final mapGrowthKb = await _writeGrowthKb('map', n);

      printOnFailure(
        'write-workload growth: sqlite=$sqliteGrowthKb KB, map=$mapGrowthKb KB',
      );

      // The SQLite page cache bounds working memory independent of dataset
      // size. Locally this is ~9 MB for 100k single-field docs; 40 MB is
      // generous headroom for a slower or noisier CI host.
      expect(
        sqliteGrowthKb,
        lessThan(40 * 1024),
        reason: 'disk-backed engine should not grow with the dataset',
      );

      // MapCrdtTable keeps every record live in RAM, so the identical workload
      // must cost materially more. Locally ~64 MB vs ~9 MB.
      expect(
        mapGrowthKb,
        greaterThan(sqliteGrowthKb + 15 * 1024),
        reason: 'in-memory engine should be materially heavier for the same N',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<int> _writeGrowthKb(String engine, int n) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', _benchmarkScript(), '--engine=$engine', '--n=$n'],
  );
  if (result.exitCode != 0) {
    fail('benchmark ($engine) exited ${result.exitCode}:\n'
        '${result.stdout}\n${result.stderr}');
  }
  final match =
      RegExp(r'WRITE_GROWTH_KB=(\d+)').firstMatch(result.stdout as String);
  if (match == null) {
    fail('no WRITE_GROWTH_KB line in benchmark output:\n${result.stdout}');
  }
  return int.parse(match.group(1)!);
}

/// Locates the benchmark script whether the test is run from the package
/// directory (melos) or the repository root.
String _benchmarkScript() {
  const candidates = [
    'benchmark/memory_benchmark.dart',
    'packages/conclave_core/benchmark/memory_benchmark.dart',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  fail('cannot find memory_benchmark.dart from ${Directory.current.path}');
}
