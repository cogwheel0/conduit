// Moves tests of extracted code into `packages/conduit_core/test` (WP-1.15).
//
//   dart run tool/migrate_core_tests.dart [--apply]
//
// Without `--apply` it reports what it would do and changes nothing.
//
// A test can move only when it already depends on nothing but the core. That
// is the whole check: the point of the extraction is that this code no longer
// needs Flutter, and a test that still reaches for `package:conduit` or
// `package:flutter` is evidence that something did not actually come out.
// Such a file is reported as blocked, with the offending import named, rather
// than moved and patched into compiling.
//
// The one rewrite applied is the test framework: `flutter_test` exists to
// drive a widget tree, and these tests have none. Swapping it for
// `package:test` is what lets `dart test` in the package cover the extracted
// code without a Flutter toolchain — which is the point of the milestone.
import 'dart:io';

/// Imports that prove a test still belongs to the app.
const List<String> _blockingImports = <String>[
  'package:conduit/',
  'package:flutter/',
  'package:flutter_riverpod/',
  'package:drift_flutter/',
  'package:path_provider/',
  'package:shared_preferences/',
];

/// Rewritten on the way in.
const Map<String, String> _importRewrites = <String, String>{
  'package:flutter_test/flutter_test.dart': 'package:test/test.dart',
};

final RegExp _importRegex = RegExp(
  '''^\\s*import\\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

void main(List<String> args) {
  final apply = args.contains('--apply');
  final root = Directory('test');
  if (!root.existsSync()) {
    stderr.writeln('run from the repository root');
    exit(1);
  }

  final movable = <_Candidate>[];
  final blocked = <_Candidate>[];
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('_test.dart')) continue;
    final content = entity.readAsStringSync();
    final imports = _importRegex
        .allMatches(content)
        .map((m) => m.group(1)!)
        .toList();
    if (!imports.any((i) => i.startsWith('package:conduit_core/'))) continue;

    final blockers =
        imports
            .where((i) => _blockingImports.any(i.startsWith))
            .toSet()
            .toList()
          ..sort();
    final candidate = _Candidate(entity, blockers);
    (blockers.isEmpty ? movable : blocked).add(candidate);
  }

  movable.sort((a, b) => a.file.path.compareTo(b.file.path));
  stdout.writeln(
    '${movable.length} movable, ${blocked.length} still tied to the app',
  );
  for (final candidate in movable) {
    final target = _targetFor(candidate.file);
    stdout.writeln('  ${candidate.file.path}\n    -> $target');
    if (!apply) continue;
    final rewritten = _rewriteImports(candidate.file.readAsStringSync());
    File(target)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(rewritten);
    candidate.file.deleteSync();
  }
  if (!apply) {
    stdout.writeln('\n(dry run; pass --apply to move them)');
  }

  _reportBlockers(blocked);
}

/// Ranks what is holding the remaining tests in the app.
///
/// This is the useful half of the report. Each entry is a dependency the
/// extraction has not reached yet, and the count is how many tests would
/// follow it into the package — so it doubles as a worklist for whichever
/// work package comes next.
void _reportBlockers(List<_Candidate> blocked) {
  if (blocked.isEmpty) return;
  final counts = <String, int>{};
  for (final candidate in blocked) {
    for (final blocker in candidate.blockers) {
      counts[blocker] = (counts[blocker] ?? 0) + 1;
    }
  }
  final ranked = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('\nstill tied to the app, by dependency:');
  for (final entry in ranked) {
    stdout.writeln('  ${entry.value.toString().padLeft(4)}  ${entry.key}');
  }
}

/// Mirrors the layout under the package, minus the `core/` prefix the app
/// used to need.
String _targetFor(File file) {
  final relative = file.path
      .replaceFirst(RegExp(r'^test/'), '')
      .replaceFirst(RegExp(r'^core/'), '');
  return 'packages/conduit_core/test/$relative';
}

String _rewriteImports(String content) {
  var result = content;
  _importRewrites.forEach((from, to) {
    result = result.replaceAll("import '$from';", "import '$to';");
  });
  return result;
}

class _Candidate {
  _Candidate(this.file, this.blockers);
  final File file;
  final List<String> blockers;
}
