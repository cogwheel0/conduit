// Moves tests of extracted code into `packages/conduit_core/test`.
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
// "Depends on" includes relative imports. An earlier version of this tool
// looked only at `package:` URIs, moved 96 files, and broke 18 of them: the
// shared fixtures under `test/support` are not tests, so they were never
// candidates, and the tests that imported them landed in the package with
// their helpers left behind. Relative edges are therefore part of the graph
// here -- a helper is dragged along with the tests that use it, and a test
// whose helper cannot move is blocked by it, named as such in the report.
//
// The one rewrite applied is the test framework: `flutter_test` exists to
// drive a widget tree, and these tests have none. Swapping it for
// `package:test` is what lets `dart test` in the package cover the extracted
// code without a Flutter toolchain -- which is the point of the extraction.
// Relative imports are repointed, because `test/core/database/x_test.dart`
// and `test/database/x_test.dart` are not the same distance from `support/`.
import 'dart:io';

import 'package:path/path.dart' as p;

/// Imports that prove a test still belongs to the app.
const List<String> _blockingImports = <String>[
  'package:conduit/',
  'package:flutter/',
  'package:flutter_riverpod/',
  'package:drift_flutter/',
  'package:path_provider/',
  'package:shared_preferences/',
];

/// `flutter_test` API that `package:test` does not have.
///
/// Swapping the import is only sound when the test uses `flutter_test` purely
/// as a test runner. One that drives a widget tree, or initialises the
/// binding to reach a platform channel, needs Flutter and must stay. Without
/// this check the import swap succeeds and the *call* is left dangling --
/// caught at load time rather than silently, but still after the move.
const List<String> _flutterTestOnlyApi = <String>[
  'TestWidgetsFlutterBinding',
  'testWidgets',
  'WidgetTester',
  'matchesGoldenFile',
  'TestDefaultBinaryMessenger',
  'IntegrationTestWidgetsFlutterBinding',
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
  if (!Directory('test').existsSync()) {
    stderr.writeln('run from the repository root');
    exit(1);
  }

  final graph = _scan();
  final movable = _resolveMovable(graph);

  final roots = graph.keys.where((f) => graph[f]!.isRoot).toList()..sort();
  final movableRoots = roots.where(movable.contains).toList();
  final blockedRoots = roots.where((f) => !movable.contains(f)).toList();
  final helpers = movable.where((f) => !graph[f]!.isRoot).toList()..sort();

  stdout.writeln(
    '${movableRoots.length} movable '
    '(${helpers.length} shared helpers move with them), '
    '${blockedRoots.length} still tied to the app',
  );
  for (final file in [...movableRoots, ...helpers]) {
    stdout.writeln('  $file\n    -> ${_targetFor(file)}');
  }
  if (apply) {
    _apply([...movableRoots, ...helpers], graph);
  } else {
    stdout.writeln('\n(dry run; pass --apply to move them)');
  }

  _reportBlockers(blockedRoots, graph, movable);
}

/// Reads every Dart file under `test/` into a dependency graph.
Map<String, _Node> _scan() {
  final graph = <String, _Node>{};
  for (final entity in Directory('test').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = p.normalize(entity.path);
    final content = entity.readAsStringSync();
    final imports = _importRegex
        .allMatches(content)
        .map((m) => m.group(1)!)
        .toList();
    final flutterTestApi = _flutterTestOnlyApi
        .where((id) => RegExp('\\b$id\\b').hasMatch(content))
        .map((id) => 'flutter_test API: $id');
    graph[path] = _Node(
      isRoot:
          path.endsWith('_test.dart') &&
          imports.any((i) => i.startsWith('package:conduit_core/')),
      packageBlockers: <String>{
        ...imports.where((i) => _blockingImports.any(i.startsWith)),
        ...flutterTestApi,
      },
      relativeDeps: imports
          .where((i) => !i.startsWith('package:') && !i.startsWith('dart:'))
          .map((i) => p.normalize(p.join(p.dirname(path), i)))
          .toSet(),
    );
  }
  return graph;
}

/// The largest set of files that can move without leaving a dangling edge.
///
/// Starts optimistic and shrinks to a fixed point, which is the direction
/// that terminates: every rule here only ever removes a file. Three rules,
/// and the third is the one the first version of this tool was missing.
///
///  - a file with a blocking `package:` import cannot move;
///  - a file cannot move if something it imports is staying;
///  - a helper cannot move if anything that imports it is staying, because
///    the file left behind would lose it.
Set<String> _resolveMovable(Map<String, _Node> graph) {
  final dependents = <String, Set<String>>{};
  for (final entry in graph.entries) {
    for (final dep in entry.value.relativeDeps) {
      dependents.putIfAbsent(dep, () => <String>{}).add(entry.key);
    }
  }

  // Only files reachable from a root are candidates at all; a helper used by
  // nothing movable has no reason to move.
  final candidates = <String>{};
  void walk(String file) {
    if (!candidates.add(file)) return;
    for (final dep in graph[file]?.relativeDeps ?? const <String>{}) {
      walk(dep);
    }
  }

  for (final entry in graph.entries) {
    if (entry.value.isRoot) walk(entry.key);
  }

  final movable = candidates.where((f) {
    final node = graph[f];
    return node != null && node.packageBlockers.isEmpty;
  }).toSet();

  var changed = true;
  while (changed) {
    changed = false;
    for (final file in movable.toList()) {
      final staysBehind =
          graph[file]!.relativeDeps.any((d) => !movable.contains(d)) ||
          (!graph[file]!.isRoot &&
              (dependents[file] ?? const <String>{}).any(
                (d) => !movable.contains(d),
              ));
      if (staysBehind) {
        movable.remove(file);
        changed = true;
      }
    }
  }
  return movable;
}

void _apply(List<String> files, Map<String, _Node> graph) {
  final targets = {for (final f in files) f: _targetFor(f)};
  for (final file in files) {
    final rewritten = _rewrite(File(file).readAsStringSync(), file, targets);
    File(targets[file]!)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(rewritten);
    File(file).deleteSync();
  }
}

/// Ranks what is holding the remaining tests in the app.
///
/// This is the useful half of the report. Each entry is a dependency the
/// extraction has not reached yet, and the count is how many tests would
/// follow it into the package -- so it doubles as a worklist for whatever
/// is extracted next.
void _reportBlockers(
  List<String> blocked,
  Map<String, _Node> graph,
  Set<String> movable,
) {
  if (blocked.isEmpty) return;
  final counts = <String, int>{};
  for (final file in blocked) {
    for (final blocker in _blockersOf(file, graph, movable, <String>{})) {
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

/// What actually holds `file` back, looking through relative imports.
///
/// A test blocked only because a helper it shares is pinned by *another*
/// test would otherwise report nothing, which is the least useful answer
/// available. Naming the helper says where to look.
Set<String> _blockersOf(
  String file,
  Map<String, _Node> graph,
  Set<String> movable,
  Set<String> seen,
) {
  if (!seen.add(file)) return <String>{};
  final node = graph[file];
  if (node == null) return {'missing: $file'};
  final blockers = <String>{...node.packageBlockers};
  for (final dep in node.relativeDeps) {
    if (movable.contains(dep)) continue;
    final inherited = _blockersOf(dep, graph, movable, seen);
    blockers.addAll(inherited.isEmpty ? {'shared helper: $dep'} : inherited);
  }
  return blockers;
}

/// Mirrors the layout under the package, minus the `core/` prefix the app
/// used to need.
String _targetFor(String file) {
  final relative = file
      .replaceFirst(RegExp(r'^test/'), '')
      .replaceFirst(RegExp(r'^core/'), '');
  return 'packages/conduit_core/test/$relative';
}

String _rewrite(String content, String from, Map<String, String> targets) {
  var result = content;
  _importRewrites.forEach((oldUri, newUri) {
    result = result.replaceAll("import '$oldUri';", "import '$newUri';");
  });
  // Dropping the `core/` segment changes how far a file sits from its
  // fixtures, so the old relative URI is wrong at the destination even
  // though both ends moved.
  return result.replaceAllMapped(_importRegex, (match) {
    final uri = match.group(1)!;
    if (uri.startsWith('package:') || uri.startsWith('dart:')) {
      return match.group(0)!;
    }
    final resolved = p.normalize(p.join(p.dirname(from), uri));
    final target = targets[resolved];
    if (target == null) throw StateError('$from imports unmoved $resolved');
    final rebased = p.relative(target, from: p.dirname(targets[from]!));
    return match.group(0)!.replaceFirst(uri, rebased);
  });
}

class _Node {
  _Node({
    required this.isRoot,
    required this.packageBlockers,
    required this.relativeDeps,
  });

  /// A test of extracted code -- the reason anything moves.
  final bool isRoot;
  final Set<String> packageBlockers;
  final Set<String> relativeDeps;
}
