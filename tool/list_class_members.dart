// Prints a class's members as TSV, so a large class can be split along real
// boundaries instead of hand-counted lines.
//
//   dart run tool/list_class_members.dart <file.dart> <ClassName>
//
// Emits `startLine<TAB>endLine<TAB>kind<TAB>name<TAB>callees`, 1-based and
// inclusive. Ranges partition the class body exactly: a member starts on the
// first non-blank line after the previous one, so doc comments and banner
// comments attach to the member they precede and no line is dropped.
//
// `callees` lists the class's own members that appear inside this member's
// text. It is matched by name, so it over-approximates -- a local variable
// sharing a member's name counts. That is the safe direction: the split uses
// it to decide which members need an abstract declaration on the shared base,
// and a spurious entry costs one unnecessary declaration, while a missing one
// would not compile.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: list_class_members.dart <file.dart> <ClassName>');
    exit(64);
  }
  final file = File(args[0]);
  final source = file.readAsStringSync();
  final result = parseString(content: source, path: file.path);
  final lines = source.split('\n');
  int lineOf(int offset) => result.lineInfo.getLocation(offset).lineNumber;

  final target = result.unit.declarations
      .whereType<ClassDeclaration>()
      .where(
        (c) => source.substring(c.offset, c.end).contains('class ${args[1]}'),
      )
      .firstOrNull;
  if (target == null) {
    stderr.writeln('class ${args[1]} not found');
    exit(1);
  }

  final members = target.body.members;
  final names = <String>{};
  final spans = <List<Object>>[];
  var cursor = lineOf(target.offset) + 1;
  for (final member in members) {
    final end = lineOf(member.end - 1);
    var start = cursor;
    while (start < end && lines[start - 1].trim().isEmpty) {
      start++;
    }
    // Walk past doc comments, banner comments and annotations, then keep
    // going while the signature wraps -- a record or generic return type puts
    // the member's own name several lines below where its range starts.
    var name = '?';
    for (var probe = start; probe <= end && name == '?'; probe++) {
      final line = lines[probe - 1];
      if (_isCommentOrAnnotation(line) || line.trim().isEmpty) continue;
      name = _name(line);
    }
    names.add(name);
    spans.add([
      start,
      end,
      member.runtimeType.toString().replaceAll('Impl', ''),
      name,
    ]);
    cursor = end + 1;
  }

  for (final span in spans) {
    final text = lines.sublist((span[0] as int) - 1, span[1] as int).join('\n');
    final callees =
        names
            .where((n) => n != span[3] && n.length > 2)
            .where(
              (n) =>
                  RegExp('(?<![A-Za-z0-9_])$n(?![A-Za-z0-9_])').hasMatch(text),
            )
            .toList()
          ..sort();
    stdout.writeln(
      '${span[0]}\t${span[1]}\t${span[2]}\t${span[3]}\t${callees.join(',')}',
    );
  }
}

bool _isCommentOrAnnotation(String line) {
  final t = line.trimLeft();
  return t.startsWith('//') ||
      t.startsWith('/*') ||
      t.startsWith('*') ||
      t.startsWith('@');
}

final _namePattern = RegExp(
  r'(?:^|\s)(?:get|set)\s+(\w+)'
  r'|(\w+)\s*(?:<[^>]*>)?\s*\('
  r'|(\w+)\s*[=;]',
);

String _name(String line) {
  final m = _namePattern.firstMatch(line.trim());
  if (m == null) return '?';
  for (var g = 1; g <= m.groupCount; g++) {
    final v = m.group(g);
    if (v != null) return v;
  }
  return '?';
}
