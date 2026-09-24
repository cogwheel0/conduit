// Moves members of one oversized class into `part` files, wrapping each group
// in its own declaration.
//
//   dart run tool/split_class_into_mixins.dart <library.dart> <plan.tsv>
//
// The plan is tab-separated, one line per member range:
//   startLine <TAB> endLine <TAB> outputFile <TAB> wrapperDeclaration
// Lines are 1-based inclusive and must not overlap. Ranges sharing an
// outputFile are gathered in file order into a single declaration, so a
// family whose members are scattered through the original still lands in one
// place. `wrapperDeclaration` is the text opening that declaration, for
// example `mixin _ChatsApi on _ApiServiceBase`; it need only be given once
// per output file.
//
// Why a mixin and not an extension: extension members resolve statically, so
// the 60 `extends ApiService` fakes and 9 `implements` mocks in the test
// suite would be silently bypassed. Mixin members are real virtual members.
// Why a mixin and not delegation: the bodies move verbatim, because `_dio`,
// `serverConfig` and the private helpers still resolve through the base.
//
// Members left unmentioned by the plan stay where they are. Like
// split_into_parts.dart, this refuses to report success unless every
// non-blank line of the original still exists exactly once afterwards.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'usage: split_class_into_mixins.dart <library.dart> <plan.tsv>',
    );
    exit(64);
  }
  final library = File(args[0]);
  final original = library.readAsLinesSync();

  final cuts = <_Cut>[];
  final wrappers = <String, String>{};
  for (final raw in File(args[1]).readAsLinesSync()) {
    if (raw.trim().isEmpty || raw.startsWith('#')) continue;
    final f = raw.split('\t');
    final cut = _Cut(int.parse(f[0]), int.parse(f[1]), f[2]);
    cuts.add(cut);
    if (f.length > 3 && f[3].trim().isNotEmpty) {
      final existing = wrappers[cut.file];
      if (existing != null && existing != f[3]) {
        stderr.writeln('conflicting wrappers for ${cut.file}');
        exit(1);
      }
      wrappers[cut.file] = f[3];
    }
  }
  cuts.sort((a, b) => a.start.compareTo(b.start));
  for (var i = 0; i < cuts.length; i++) {
    final c = cuts[i];
    if (c.start < 1 || c.end > original.length || c.start > c.end) {
      stderr.writeln('bad range ${c.start}-${c.end} for ${c.file}');
      exit(1);
    }
    if (i > 0 && c.start <= cuts[i - 1].end) {
      stderr.writeln('overlap: ${cuts[i - 1].file} and ${c.file}');
      exit(1);
    }
    if (!wrappers.containsKey(c.file)) {
      stderr.writeln('no wrapper declaration given for ${c.file}');
      exit(1);
    }
  }

  final bodies = <String, List<String>>{};
  final removals = <int>{};
  for (final cut in cuts) {
    bodies
        .putIfAbsent(cut.file, () => <String>[])
        .addAll(original.sublist(cut.start - 1, cut.end));
    for (var i = cut.start - 1; i < cut.end; i++) {
      removals.add(i);
    }
  }

  final kept = <String>[
    for (var i = 0; i < original.length; i++)
      if (!removals.contains(i)) original[i],
  ];
  final anchor = _directiveAnchor(original, kept);
  final directives = bodies.keys.map((f) => "part '$f';").toList()..sort();
  kept.insertAll(anchor + 1, directives);

  final dir = library.parent.path;
  final libraryName = library.uri.pathSegments.last;
  final outputs = <String, String>{
    library.path: '${kept.join('\n').trimRight()}\n',
    for (final entry in bodies.entries)
      '$dir/${entry.key}':
          "part of '$libraryName';\n\n"
          "${wrappers[entry.key]} {\n${entry.value.join('\n').trimRight()}\n}\n",
  };

  // Verify before writing anything. A tool that detects a bad plan and leaves
  // the source truncated behind it is worse than one that never ran.
  _assertNothingLost(original, kept, directives, bodies, wrappers);
  _assertStillParses(outputs);

  outputs.forEach((path, content) => File(path).writeAsStringSync(content));

  stdout.writeln('$libraryName: ${original.length} -> ${kept.length} lines');
  for (final entry in bodies.entries) {
    stdout.writeln('  ${entry.key}: ${entry.value.length} lines');
  }
}

/// Proves the move relocated code rather than changing it: every non-blank
/// line of the original appears exactly as often afterwards, and the only new
/// lines are the `part` directives, the `part of` headers and the wrapper
/// declarations with their closing braces.
void _assertNothingLost(
  List<String> original,
  List<String> kept,
  List<String> directives,
  Map<String, List<String>> bodies,
  Map<String, String> wrappers,
) {
  Map<String, int> tally(Iterable<String> lines) {
    final counts = <String, int>{};
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      counts[line] = (counts[line] ?? 0) + 1;
    }
    return counts;
  }

  final before = tally(original);
  final after = tally([
    ...kept.where((l) => !directives.contains(l)),
    for (final body in bodies.values) ...body,
  ]);
  final problems = <String>[];
  for (final key in {...before.keys, ...after.keys}) {
    if (before[key] != after[key]) {
      problems.add('  ${before[key] ?? 0} -> ${after[key] ?? 0}  $key');
    }
  }
  if (problems.isNotEmpty) {
    stderr.writeln('content changed, refusing to claim success:');
    problems.take(20).forEach(stderr.writeln);
    exit(1);
  }
}

/// Finds the line to insert the new `part` directives after: the last
/// hand-written part if the library already has some, otherwise the end of
/// the directive block. The end of that block comes from the parser rather
/// than a line scan, because a wrapped `export ... show a, b, c;` spans
/// several lines and only the last of them ends the directive.
int _directiveAnchor(List<String> original, List<String> kept) {
  final existing = kept.lastIndexWhere(
    (l) => l.startsWith("part '") && !l.endsWith(".g.dart';"),
  );
  if (existing != -1) return existing;

  final parsed = parseString(
    content: original.join('\n'),
    path: 'anchor',
    throwIfDiagnostics: false,
  );
  if (parsed.unit.directives.isEmpty) {
    stderr.writeln('library has no directives to anchor the new parts after');
    exit(1);
  }
  final lastLine = parsed.lineInfo
      .getLocation(parsed.unit.directives.last.end - 1)
      .lineNumber;
  // Directives precede every member, so removals never shift this line.
  return lastLine - 1;
}

/// Content preservation is not enough on its own: a range that is off by one
/// can carry the class's own closing brace into a part file, and every line
/// still exists exactly once afterwards. Only parsing catches that, so the
/// tool refuses to report success on output it cannot parse.
void _assertStillParses(Map<String, String> outputs) {
  final broken = <String>[];
  for (final entry in outputs.entries) {
    final result = parseString(
      content: entry.value,
      path: entry.key,
      throwIfDiagnostics: false,
    );
    for (final error in result.errors) {
      broken.add('  ${entry.key}: ${error.message}');
    }
  }
  if (broken.isNotEmpty) {
    stderr.writeln('output does not parse, the ranges are wrong:');
    broken.take(10).forEach(stderr.writeln);
    exit(1);
  }
}

class _Cut {
  _Cut(this.start, this.end, this.file);
  final int start;
  final int end;
  final String file;
}
