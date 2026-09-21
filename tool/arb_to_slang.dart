// Converts the ARB catalog in lib/l10n into slang's input format (WP-0.8).
//
//   dart run tool/arb_to_slang.dart
//
// Why a conversion step exists at all: the ARB files are the single source of
// truth for both apps, but slang's own ARB importer cannot read them.
//
//   * It only recognizes an ICU plural when the plural is the *entire* value
//     (`RegexUtils.arbComplexNode` is anchored), so
//     `'{count} {count, plural, ...}'` fails outright.
//   * Its data model allows one plural parameter per key, while Polish
//     legitimately pluralizes two (`hermesSchedulesSummary`).
//   * The same key is a plural in some locales and a plain string in others,
//     because `gen-l10n` compiles each locale independently and translators
//     took advantage of it. slang needs one shape for all locales.
//
// This tool normalizes all three, writing slang JSON that produces the same
// rendered output. It never modifies lib/l10n.
import 'dart:convert';
import 'dart:io';

/// ARB categories that mean "exactly this number" map onto the CLDR category
/// of the same name. slang's resolvers check `n == 0` and `n == 1` before
/// falling back, so `=0` and `=1` keep their exact-match behaviour.
const Map<String, String> _categoryAliases = <String, String>{
  '=0': 'zero',
  '=1': 'one',
  '=2': 'two',
};

void main(List<String> args) {
  final inputDir = Directory(args.isNotEmpty ? args[0] : 'lib/l10n');
  final outputDir = Directory(
    args.length > 1 ? args[1] : 'apps/desktop_ui/build/slang',
  );

  // Recursive: `flutter gen-l10n` refuses two files claiming the same locale
  // in one directory, so non-mobile namespaces live in subdirectories
  // (lib/l10n/desktop/) that gen-l10n does not scan.
  final files =
      inputDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.arb'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln('No .arb files in ${inputDir.path}');
    exit(1);
  }

  // namespace -> locale -> key -> raw string
  final catalogs = <String, Map<String, Map<String, String>>>{};
  for (final file in files) {
    final name = file.uri.pathSegments.last.replaceAll('.arb', '');
    final split = name.indexOf('_');
    if (split <= 0) {
      stderr.writeln('Skipping $name: expected <namespace>_<locale>.arb');
      continue;
    }
    final namespace = name.substring(0, split);
    final locale = name.substring(split + 1);
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final strings = <String, String>{};
    decoded.forEach((key, value) {
      // `@key` metadata and `@@locale` are ARB bookkeeping, not translations.
      if (key.startsWith('@')) return;
      if (value is String) strings[key] = value;
    });
    (catalogs[namespace] ??= <String, Map<String, String>>{})[locale] = strings;
  }

  outputDir.createSync(recursive: true);
  var totalKeys = 0;
  for (final namespace in catalogs.keys) {
    final locales = catalogs[namespace]!;
    // Decide each key's shape once, across every locale, so all locales emit
    // the same structure — slang builds one model for the whole catalog.
    final pluralParams = <String, List<String>>{};
    for (final strings in locales.values) {
      strings.forEach((key, value) {
        final params = _parse(value)
            .whereType<_PluralSegment>()
            .map((s) => s.parameter)
            .toList();
        if (params.isEmpty) return;
        final known = pluralParams[key];
        if (known == null || params.length > known.length) {
          pluralParams[key] = params;
        }
      });
    }

    for (final entry in locales.entries) {
      final out = <String, dynamic>{};
      entry.value.forEach((key, value) {
        final params = pluralParams[key];
        if (params == null) {
          out[key] = value;
          return;
        }
        if (params.length == 1) {
          _emitFolded(out, key, params.single, value);
        } else {
          _emitLinked(out, namespace, key, params, value);
        }
      });
      totalKeys = out.length;
      File('${outputDir.path}/${namespace}_${entry.key}.i18n.json')
          .writeAsStringSync(
            '${const JsonEncoder.withIndent('  ').convert(out)}\n',
          );
    }
    stdout.writeln(
      'namespace "$namespace": ${locales.length} locales, $totalKeys keys, '
      '${pluralParams.length} pluralized',
    );
  }
  stdout.writeln('Wrote slang input to ${outputDir.path}');
}

/// A single plural: fold any surrounding text into every branch.
///
/// `'{count} {count, plural, =1{member} other{members}}'` becomes
/// `{one: '{count} member', other: '{count} members'}`, which renders
/// identically and needs no linked sub-key.
void _emitFolded(
  Map<String, dynamic> out,
  String key,
  String parameter,
  String value,
) {
  final segments = _parse(value);
  final plural = segments.whereType<_PluralSegment>().firstOrNull;
  if (plural == null) {
    // This locale wrote a plain string where others pluralize. `other` alone
    // renders exactly what it says today, for every count.
    out['$key(param=$parameter)'] = <String, String>{'other': value};
    return;
  }
  final prefix = segments
      .takeWhile((s) => s != plural)
      .whereType<_TextSegment>()
      .map((s) => s.text)
      .join();
  final suffix = segments
      .skipWhile((s) => s != plural)
      .skip(1)
      .whereType<_TextSegment>()
      .map((s) => s.text)
      .join();
  out['$key(param=$parameter)'] = <String, String>{
    for (final branch in plural.branches.entries)
      branch.key: '$prefix${branch.value}$suffix',
  };
}

/// Two or more plurals in one message: give each its own key and link them.
///
/// slang unions the parameters of linked translations into the parent's
/// signature, so the caller still sees one method taking every placeholder.
void _emitLinked(
  Map<String, dynamic> out,
  String namespace,
  String key,
  List<String> parameters,
  String value,
) {
  final segments = _parse(value);
  final buffer = StringBuffer();
  final seen = <String>{};
  for (final segment in segments) {
    switch (segment) {
      case _TextSegment(:final text):
        // A parameter that drives a plural in *any* locale is `num`
        // everywhere. English writes `{active} active` as a plain
        // interpolation while Polish pluralizes it; without the annotation
        // slang types the base locale's parameter as `Object` and the
        // override in the Polish class fails to compile.
        buffer.write(_annotateNumeric(text, parameters));
      case _PluralSegment(:final parameter, :final branches):
        final child = '${key}__plural_$parameter';
        out['$child(param=$parameter)'] = branches;
        seen.add(parameter);
        buffer.write('@:$namespace.$child');
    }
  }
  // Every locale must define every sub-key, even the ones it does not
  // pluralize, or slang sees a key missing from some locales.
  for (final parameter in parameters) {
    if (seen.contains(parameter)) continue;
    out['${key}__plural_$parameter(param=$parameter)'] = <String, String>{
      'other': '',
    };
  }
  out[key] = buffer.toString();
}

/// Rewrites `{p}` to `{p: num}` for every p in [parameters].
String _annotateNumeric(String text, List<String> parameters) {
  var result = text;
  for (final parameter in parameters) {
    result = result.replaceAll('{$parameter}', '{$parameter: num}');
  }
  return result;
}

sealed class _Segment {
  const _Segment();
}

class _TextSegment extends _Segment {
  const _TextSegment(this.text);
  final String text;
}

class _PluralSegment extends _Segment {
  const _PluralSegment(this.parameter, this.branches);
  final String parameter;

  /// CLDR category -> branch text, in source order.
  final Map<String, String> branches;
}

final RegExp _pluralStart = RegExp(r'\{\s*(\w+)\s*,\s*plural\s*,');

/// Splits an ICU message into literal text and plural blocks.
///
/// Brace-matched rather than regex-matched: plural branches contain nested
/// `{placeholder}` braces, which no single regex handles correctly.
List<_Segment> _parse(String value) {
  final segments = <_Segment>[];
  var cursor = 0;
  while (cursor < value.length) {
    final match = _pluralStart.firstMatch(value.substring(cursor));
    if (match == null) {
      segments.add(_TextSegment(value.substring(cursor)));
      break;
    }
    final start = cursor + match.start;
    if (start > cursor) {
      segments.add(_TextSegment(value.substring(cursor, start)));
    }
    final end = _matchBrace(value, start);
    if (end == -1) {
      // Unbalanced braces: treat the rest as literal rather than guessing.
      segments.add(_TextSegment(value.substring(start)));
      break;
    }
    final body = value.substring(cursor + match.end, end);
    segments.add(_PluralSegment(match.group(1)!, _parseBranches(body)));
    cursor = end + 1;
  }
  return segments;
}

/// Index of the `}` closing the `{` at [open], or -1.
int _matchBrace(String value, int open) {
  var depth = 0;
  for (var i = open; i < value.length; i++) {
    if (value[i] == '{') depth++;
    if (value[i] == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// Parses `=1{one thing} other{{n} things}` into a category map.
Map<String, String> _parseBranches(String body) {
  final branches = <String, String>{};
  var cursor = 0;
  while (cursor < body.length) {
    while (cursor < body.length && body[cursor].trim().isEmpty) {
      cursor++;
    }
    if (cursor >= body.length) break;
    final brace = body.indexOf('{', cursor);
    if (brace == -1) break;
    final category = body.substring(cursor, brace).trim();
    final end = _matchBrace(body, brace);
    if (end == -1) break;
    branches[_categoryAliases[category] ?? category] = body.substring(
      brace + 1,
      end,
    );
    cursor = end + 1;
  }
  return branches;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
