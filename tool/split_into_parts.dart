// Moves line ranges of a Dart library into `part` files (WP-1.10).
//
//   dart run tool/split_into_parts.dart <library.dart> <plan.tsv>
//
// The plan is tab-separated: `startLine<TAB>endLine<TAB>partFileName`, 1-based
// and inclusive. Ranges must not overlap; naming the same file more than once
// appends the ranges in file order, which is how a domain that got interleaved
// with an unrelated one still lands in a single part.
//
// Why a tool rather than an editor: chat_providers.dart is 19,509 lines and a
// cut has to be exact. A declaration split across two files is a compile error
// the analyzer catches, but a cut that swallows a leading doc comment is not.
// So this moves ranges verbatim, never reformats, and asserts afterwards that
// every line of the original still exists exactly once across the outputs.
import 'dart:io';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: split_into_parts.dart <library.dart> <plan.tsv>');
    exit(64);
  }
  final library = File(args[0]);
  final original = library.readAsLinesSync();

  final cuts = <_Cut>[];
  for (final raw in File(args[1]).readAsLinesSync()) {
    if (raw.trim().isEmpty || raw.startsWith('#')) continue;
    final f = raw.split('\t');
    cuts.add(_Cut(int.parse(f[0]), int.parse(f[1]), f[2]));
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
  }

  final dir = library.parent.path;
  final libraryName = library.uri.pathSegments.last;

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
  // Anchor after the last hand-written part, so the new directives stay
  // grouped with their peers and the generated one keeps the last slot.
  final anchor = kept.lastIndexWhere(
    (l) => l.startsWith("part '") && !l.endsWith(".g.dart';"),
  );
  if (anchor == -1) {
    stderr.writeln('no existing `part` directive to anchor the new ones');
    exit(1);
  }
  final directives = bodies.keys.map((f) => "part '$f';").toList()..sort();
  kept.insertAll(anchor + 1, directives);

  for (final entry in bodies.entries) {
    File('$dir/${entry.key}').writeAsStringSync(
      "part of '$libraryName';\n\n${entry.value.join('\n').trim()}\n",
    );
  }
  library.writeAsStringSync('${kept.join('\n').trimRight()}\n');

  _assertNothingLost(original, kept, directives, bodies);

  stdout.writeln('$libraryName: ${original.length} -> ${kept.length} lines');
  for (final entry in bodies.entries) {
    stdout.writeln('  ${entry.key}: ${entry.value.length} lines');
  }
}

/// Proves the move was a pure relocation: every non-blank line of the original
/// appears exactly as often across the root and the parts, and nothing new
/// appears beyond the `part` directives and the `part of` headers.
void _assertNothingLost(
  List<String> original,
  List<String> kept,
  List<String> directives,
  Map<String, List<String>> bodies,
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

class _Cut {
  _Cut(this.start, this.end, this.file);
  final int start;
  final int end;
  final String file;
}
