import 'dart:convert';
import 'dart:io';

/// Validates ARB locale files against their English template.
/// - Ensures each non-meta key in EN exists in other locales.
/// - Reports keys a locale defines that EN does not (orphans left behind when
///   a key is renamed or removed).
/// - Ensures placeholder names match between EN and other locales.
/// - Reports unused keys (best-effort) by scanning the Flutter app and the
///   desktop UI for the key name. Unused keys are WARNINGS by default.
///
/// ARB files are grouped into namespaces by their filename prefix, so
/// `app_*.arb` is validated against `app_en.arb` and `desktop_*.arb` against
/// `desktop_en.arb`. Without this the desktop catalog would be
/// compared against the mobile template and every key would look missing.
///
/// Exit codes:
///   0 = success (no hard errors; warnings may be printed)
///   1 = validation errors (missing keys, missing template)
Future<void> main(List<String> args) async {
  final dir = Directory('lib/l10n');
  if (!await dir.exists()) {
    stderr.writeln('ARB directory not found: ${dir.path}');
    exit(1);
  }

  // Recursive: `flutter gen-l10n` refuses two files claiming the same locale
  // in one directory, so non-mobile namespaces live in subdirectories
  // (lib/l10n/desktop/) that gen-l10n does not scan.
  final allArb = await dir
      .list(recursive: true)
      .where((e) => e.path.endsWith('.arb'))
      .map((e) => File(e.path))
      .toList();

  // <namespace> -> files, from `<namespace>_<locale>.arb`.
  final namespaces = <String, List<File>>{};
  for (final file in allArb) {
    final name = file.uri.pathSegments.last.replaceAll('.arb', '');
    final split = name.indexOf('_');
    if (split <= 0) {
      stderr.writeln(
        'Ignoring ${file.path}: expected <namespace>_<locale>.arb',
      );
      continue;
    }
    namespaces.putIfAbsent(name.substring(0, split), () => <File>[]).add(file);
  }
  if (namespaces.isEmpty) {
    stderr.writeln('No ARB files found in ${dir.path}');
    exit(1);
  }

  final errors = <String>[];
  final warnings = <String>[];
  final allBaseKeys = <String>{};

  for (final namespace in namespaces.keys.toList()..sort()) {
    final template = namespaces[namespace]!.firstWhere(
      (f) => f.path.endsWith('_en.arb'),
      orElse: () => File(''),
    );
    final basePath = template.path;
    if (basePath.isEmpty || !await File(basePath).exists()) {
      errors.add('Namespace "$namespace" has no English template ($basePath)');
      continue;
    }
    final arbFiles = namespaces[namespace]!;
    final base = _readJson(File(basePath));
    final baseKeys = _nonMetaKeys(base);
    final basePlaceholders = _placeholdersMap(base);
    allBaseKeys.addAll(baseKeys);

    // NOTE: Duplicate keys at the top-level are invalid JSON and unlikely.
    // We skip duplicate detection to avoid false positives from nested meta
    // keys.

    // Validate translations against base
    for (final f in arbFiles) {
      if (f.path.endsWith('_en.arb')) continue;
      final data = _readJson(f);
      final keys = _nonMetaKeys(data);

      // Missing keys
      final missing = baseKeys.difference(keys);
      if (missing.isNotEmpty) {
        errors.add('[${f.path}] Missing keys: ${missing.toList()..sort()}');
      }

      // Keys this locale has but EN does not. Usually a translation left
      // behind when the English key was renamed or deleted: it is dead
      // weight, and it makes every non-Flutter generator (slang)
      // emit a locale class that does not match the base.
      final orphaned = keys.difference(baseKeys);
      if (orphaned.isNotEmpty) {
        warnings.add(
          '[${f.path}] Keys not present in $basePath: ${orphaned.toList()..sort()}',
        );
      }

      // Placeholder parity checks
      final transPlaceholders = _placeholdersMap(data);
      for (final k in basePlaceholders.keys) {
        final basePh = basePlaceholders[k] ?? const <String>{};
        final trPh = transPlaceholders[k];
        if (trPh == null) {
          // If string exists but no meta placeholders, warn only.
          if (keys.contains(k) && basePh.isNotEmpty) {
            warnings.add(
              '[${f.path}] Key "$k" missing @meta placeholders; base has ${basePh.toList()..sort()}',
            );
          }
          continue;
        }
        if (basePh.length != trPh.length || !basePh.containsAll(trPh)) {
          warnings.add(
            '[${f.path}] Placeholder mismatch for "$k": expected ${basePh.toList()..sort()}, got ${trPh.toList()..sort()}',
          );
        }
      }
    }
  }

  // Unused keys (best-effort) — WARNINGS only
  final usedKeys = await _scanUsedLocalizationKeys(allBaseKeys);
  final unused = allBaseKeys.difference(usedKeys);
  if (unused.isNotEmpty) {
    warnings.add('Unused keys in EN (best-effort): ${unused.toList()..sort()}');
  }

  // Print results
  if (errors.isNotEmpty) {
    stderr.writeln('ARB validation errors:');
    for (final e in errors) {
      stderr.writeln(' - $e');
    }
  }
  if (warnings.isNotEmpty) {
    stdout.writeln('ARB validation warnings:');
    for (final w in warnings) {
      stdout.writeln(' - $w');
    }
  }

  exit(errors.isEmpty ? 0 : 1);
}

Map<String, dynamic> _readJson(File f) {
  final content = f.readAsStringSync();
  return json.decode(content) as Map<String, dynamic>;
}

Set<String> _nonMetaKeys(Map<String, dynamic> m) {
  return m.keys.where((k) => !k.startsWith('@') && k != '@@locale').toSet();
}

Map<String, Set<String>> _placeholdersMap(Map<String, dynamic> m) {
  final map = <String, Set<String>>{};
  for (final entry in m.entries) {
    final key = entry.key;
    if (!key.startsWith('@')) continue;
    final value = entry.value;
    if (value is! Map<String, dynamic>) continue;
    final placeholders = value['placeholders'];
    if (placeholders is Map<String, dynamic>) {
      map[key.substring(1)] = placeholders.keys.toSet();
    }
  }
  return map;
}

// Duplicate detection intentionally omitted (see note above).

Future<Set<String>> _scanUsedLocalizationKeys(Set<String> baseKeys) async {
  final used = <String>{};

  // Both front-ends consume the same catalog, so a key used only by the
  // desktop UI must not be reported as unused.
  final sourceRoots = <Directory>[
    Directory('lib'),
    Directory('apps/desktop_ui/lib'),
  ].where((d) => d.existsSync()).toList();

  Future<bool> keyIsUsed(String key) async {
    try {
      if (sourceRoots.isEmpty) {
        return false;
      }

      for (final root in sourceRoots) {
        await for (final entity in root.list(recursive: true)) {
          if (entity is! File) continue;
          if (!entity.path.endsWith('.dart')) continue;
          if (entity.path.contains('lib/l10n/app_localizations')) continue;
          // Generated slang output restates every key, so counting it would
          // make the unused-key check always pass.
          if (entity.path.contains('desktop_ui/lib/src/l10n/')) continue;

          try {
            final content = await entity.readAsString();
            if (content.contains(key)) {
              return true;
            }
          } catch (e) {
            // Skip files that can't be read
            continue;
          }
        }
      }
      return false;
    } catch (e) {
      stderr.writeln('warning: failed to search for key "$key": $e');
      return false;
    }
  }

  for (final key in baseKeys) {
    if (await keyIsUsed(key)) {
      used.add(key);
    }
  }

  return used;
}
