#!/usr/bin/env bash
# Fails if a package under packages/ has a test/ directory that neither the
# `test:dart` nor the `test:flutter` melos script would pick up. Guards against a
# package silently dropping out of CI (see the test-runner split in the root pubspec.yaml).
set -euo pipefail
cd "$(dirname "$0")/.."

fs_pkgs=$(
  for d in packages/*/test examples/*/test; do
    [ -d "$d" ] && basename "$(dirname "$d")"
  done | sort -u
)

dart_pkgs=$(melos list --dir-exists=test --no-flutter 2>/dev/null | sort -u)
flutter_pkgs=$(melos list --dir-exists=test --flutter 2>/dev/null | sort -u)
runner_pkgs=$(printf '%s\n%s\n' "$dart_pkgs" "$flutter_pkgs" | grep -v '^$' | sort -u)

echo "packages with a test/ dir:"
printf '  %s\n' $fs_pkgs
echo "picked up by test:dart:"
printf '  %s\n' $dart_pkgs
echo "picked up by test:flutter:"
printf '  %s\n' $flutter_pkgs

if [ "$fs_pkgs" != "$runner_pkgs" ]; then
  echo "::error::A package with tests is not covered by test:dart or test:flutter."
  diff <(printf '%s\n' "$fs_pkgs") <(printf '%s\n' "$runner_pkgs") || true
  exit 1
fi

# A runner matching zero packages usually means a broken filter, not an empty
# workspace. Both partitions are expected to be non-empty here.
[ -n "$dart_pkgs" ] || { echo "::error::test:dart matched no packages."; exit 1; }
[ -n "$flutter_pkgs" ] || { echo "::error::test:flutter matched no packages."; exit 1; }

echo "OK: every package with tests is covered."
