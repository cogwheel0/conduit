import 'dart:convert';
import 'dart:io';

/// Verifies that every non-meta key in an English ARB template has a
/// corresponding @key entry with a non-empty `description`.
///
/// Covers every namespace template in lib/l10n — `app_en.arb` for the shared
/// catalog and `desktop_en.arb` for desktop-only strings — so a new
/// front-end cannot quietly skip the description requirement.
///
/// Usage: dart run tool/verify_arb_descriptions.dart
Future<void> main() async {
  final templates =
      Directory('lib/l10n')
          // Recursive: `flutter gen-l10n` refuses two files claiming the same
          // locale in one directory, so non-mobile namespaces live in
          // subdirectories (lib/l10n/desktop/) that gen-l10n does not scan.
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('_en.arb'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (templates.isEmpty) {
    stderr.writeln('No English ARB templates found in lib/l10n');
    exit(2);
  }

  var failed = false;
  for (final template in templates) {
    if (!await _verify(template)) failed = true;
  }
  exit(failed ? 1 : 0);
}

Future<bool> _verify(File file) async {
  final arbPath = file.path;

  final content = await file.readAsString();
  late final Map<String, dynamic> data;
  try {
    data = json.decode(content) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('Failed to parse $arbPath as JSON: $e');
    exit(2);
  }

  final missingMeta = <String>[];
  final missingDescription = <String>[];

  for (final entry in data.entries) {
    final key = entry.key;
    if (key.startsWith('@') || key == '@@locale') continue; // meta

    final metaKey = '@$key';
    final meta = data[metaKey];
    if (meta == null || meta is! Map) {
      missingMeta.add(key);
      continue;
    }
    final desc = meta['description'];
    if (desc is! String || desc.trim().isEmpty) {
      missingDescription.add(key);
    }
  }

  if (missingMeta.isEmpty && missingDescription.isEmpty) {
    stdout.writeln(
      'ARB descriptions check passed for $arbPath: all keys have '
      '@meta.description.',
    );
    return true;
  }

  if (missingMeta.isNotEmpty) {
    stderr.writeln(
      '[$arbPath] Missing @meta for keys (${missingMeta.length}):',
    );
    for (final k in missingMeta) {
      stderr.writeln(' - $k');
    }
  }
  if (missingDescription.isNotEmpty) {
    stderr.writeln(
      '[$arbPath] Missing description in @meta for keys '
      '(${missingDescription.length}):',
    );
    for (final k in missingDescription) {
      stderr.writeln(' - $k');
    }
  }
  return false;
}
