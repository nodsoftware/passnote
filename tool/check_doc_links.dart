// Fails (exit 1) when any internal link in the built docs site points at a
// file that does not exist. Run after `zensical build`:
//
//   dart run tool/check_doc_links.dart [site-dir] [base-path]
//
// [base-path] is the deploy prefix absolute links carry (from `site_url`),
// `/passnote/` for this site.
import 'dart:io';

final _linkPattern = RegExp('(?:href|src)="([^"]+)"');

Future<void> main(List<String> args) async {
  final siteDir = Directory(args.isEmpty ? 'site' : args.first);
  final basePath = args.length > 1 ? args[1] : '/passnote/';
  if (!siteDir.existsSync()) {
    stderr
        .writeln('No ${siteDir.path}/ directory; run `zensical build` first.');
    exit(2);
  }

  var checked = 0;
  final broken = <String>[];
  await for (final entity in siteDir.list(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.html')) continue;
    final html = await entity.readAsString();
    for (final match in _linkPattern.allMatches(html)) {
      final target = match.group(1)!;
      if (target.startsWith('http://') ||
          target.startsWith('https://') ||
          target.startsWith('mailto:') ||
          target.startsWith('data:') ||
          target.startsWith('#')) {
        continue;
      }
      checked++;
      final withoutFragment = target.split('#').first.split('?').first;
      if (withoutFragment.isEmpty) continue;
      var relative = withoutFragment;
      if (relative.startsWith(basePath)) {
        relative = relative.substring(basePath.length);
      }
      final base = relative.startsWith('/')
          ? siteDir.uri.resolve(relative.substring(1))
          : withoutFragment.startsWith('/')
              ? siteDir.uri.resolve(relative)
              : entity.parent.uri.resolve(relative);
      final asFile = File.fromUri(base);
      final asIndex = File.fromUri(base.resolve(
          base.path.endsWith('/') ? 'index.html' : '${base.path}/index.html'));
      if (!asFile.existsSync() && !asIndex.existsSync()) {
        broken.add('${entity.path}: $target');
      }
    }
  }

  if (broken.isNotEmpty) {
    stderr.writeln('Broken internal links (${broken.length}):');
    broken.forEach(stderr.writeln);
    exit(1);
  }
  stdout.writeln('Link check passed: $checked internal links resolve.');
}
