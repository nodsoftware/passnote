# Benchmarks

## Memory (`memory_benchmark.dart`)

Backs the "bounded memory" claim: the disk-backed `SqliteCrdtTable` keeps
resident memory flat as a collection grows, because SQLite serves reads from a
fixed-size page cache. `MapCrdtTable` keeps every record in RAM and is the
contrast.

### Run it

```sh
cd packages/conclave_core

# Default engine, 100k documents:
dart run benchmark/memory_benchmark.dart

# Full load and a saved report:
dart run benchmark/memory_benchmark.dart --n=1000000 \
  --out=benchmark/results/memory_$(date +%F).txt

# The in-memory contrast:
dart run benchmark/memory_benchmark.dart --engine=map --n=100000
```

Flags: `--engine=sqlite|map` (default `sqlite`), `--n=<count>` (default
`100000`), `--out=<file>` (also write the report to a file).

### Reading the numbers

The script writes N single-field documents, then reads a random 1% sample, and
records `ProcessInfo.currentRss` at checkpoints (after open, at 25/50/75/100% of
writes, after the reads).

The headline figure is **growth over the write workload** — resident set after
all writes minus resident set right after opening the engine. It ignores the
fixed ~200 MB VM/JIT baseline (and `ProcessInfo.maxRss`, whose transient JIT
peak dwarfs the workload). The machine-readable line is `WRITE_GROWTH_KB=<n>`.

A recent run (`results/memory_2026-09-07.txt`, Apple M-series, 100k docs):

| engine          | growth over 100k writes |
| --------------- | ----------------------- |
| `SqliteCrdtTable` | ~9 MB (flat from 25% on) |
| `MapCrdtTable`    | ~64 MB (linear in N)     |

### Regression guard

`test/memory_bounds_test.dart` (tag `benchmark`, skipped by default) runs both
engines at 100k and asserts the SQLite growth is under 40 MB and materially
below `MapCrdtTable`'s. CI runs it with `dart test --run-skipped -t benchmark`.
