// Prints the top-level declarations of a Dart library as TSV, so that `part`
// cuts can be planned against a real parse instead of hand-counted lines.
//
//   dart run tool/list_top_level_declarations.dart <library.dart>
//
// Emits `startLine<TAB>endLine<TAB>kind<TAB>name`, 1-based and inclusive, and
// partitions the file exactly: a declaration's range starts on the first
// non-blank line after the previous one, so interstitial comments and banners
// attach to the declaration they precede and no line is ever dropped.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

void main(List<String> args) {
  final file = File(args.single);
  final source = file.readAsStringSync();
  final result = parseString(content: source, path: file.path);
  final lineInfo = result.lineInfo;
  final lines = source.split('\n');

  int lineOf(int offset) => lineInfo.getLocation(offset).lineNumber;

  final unit = result.unit;
  var cursor = unit.directives.isEmpty
      ? 1
      : lineOf(unit.directives.last.end - 1) + 1;
  stdout.writeln('1\t${cursor - 1}\tdirectives\t<header>');

  for (final decl in unit.declarations) {
    final end = lineOf(decl.end - 1);
    var start = cursor;
    while (start < end && lines[start - 1].trim().isEmpty) {
      start++;
    }
    // A range opens with the declaration's doc comment and annotations, so
    // skip past them to find the line the name actually lives on.
    var nameLine = start;
    while (nameLine < end && _isCommentOrAnnotation(lines[nameLine - 1])) {
      nameLine++;
    }
    stdout.writeln(
      '$start\t$end\t${_kind(decl)}\t${_name(lines[nameLine - 1])}',
    );
    cursor = end + 1;
  }
  if (cursor <= lines.length) {
    stdout.writeln('$cursor\t${lines.length}\ttrailing\t<tail>');
  }
}

bool _isCommentOrAnnotation(String line) {
  final t = line.trimLeft();
  return t.startsWith('//') ||
      t.startsWith('/*') ||
      t.startsWith('*') ||
      t.startsWith('@');
}

String _kind(CompilationUnitMember decl) =>
    decl.runtimeType.toString().replaceAll('Impl', '');

// The analyzer's typed name accessors move between major versions, and the
// planner only needs a human-readable label, so read it off the source text.
final _namePattern = RegExp(
  r'\b(?:class|mixin|extension|enum|typedef)\s+(\w+)'
  r'|^(?:final|const|var|late)\s+(?:[\w<>,?\s]+\s+)?(\w+)\s*='
  r'|(\w+)\s*(?:<[^>]*>)?\s*\(',
);

String _name(String firstLine) {
  final m = _namePattern.firstMatch(firstLine.trim());
  if (m == null) return '?';
  for (var g = 1; g <= m.groupCount; g++) {
    final v = m.group(g);
    if (v != null) return v;
  }
  return '?';
}
