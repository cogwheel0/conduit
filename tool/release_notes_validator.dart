import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/release_notes/models/release_version.dart';

/// Localization keys the release-notes sheet chrome still reads from ARB.
const releaseNotesShellLocalizationKeys = <String>[
  'releaseNotesTitle',
  'releaseNotesSubtitle',
  'releaseNotesReviewButton',
  'releaseNotesDoneButton',
  'releaseNotesSupportPromptHeading',
  'releaseNotesSupportPromptMessage',
];

/// Icon names allowed in release-note JSON `icon` fields. Keep in sync with
/// `releaseNoteIcon` in
/// `lib/features/release_notes/data/release_notes_repository.dart`.
const releaseNoteValidatorIconNames = <String>{
  'local',
  'hermes',
  'direct',
  'polish',
};

const _templateLocale = 'en';

class ReleaseNotesValidationResult {
  const ReleaseNotesValidationResult(this.errors);

  final List<String> errors;

  bool get isValid => errors.isEmpty;
}

/// Validates the bundled release-note JSON assets and the shell ARB keys.
///
/// Checks per locale file: valid JSON, schema (version/title/intro/bullets),
/// versions sorted and unique, known icon names. Across locales: every file
/// carries the same version set (and per-version bullet count) as the
/// English template, and the target release version has a note.
ReleaseNotesValidationResult validateReleaseNotes({
  required String version,
  required Directory arbDirectory,
  required Directory notesDirectory,
}) {
  final errors = <String>[];
  if (ReleaseVersion.tryParse(version) == null) {
    errors.add('Release version must use x.y.z format: $version');
  }

  if (!notesDirectory.existsSync()) {
    errors.add('Missing release-notes directory: ${notesDirectory.path}');
    return ReleaseNotesValidationResult(errors);
  }

  final noteFiles =
      notesDirectory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (noteFiles.isEmpty) {
    errors.add('No release-note JSON files in ${notesDirectory.path}.');
    return ReleaseNotesValidationResult(errors);
  }

  // locale -> version -> bullet count
  final shapes = <String, Map<String, int>>{};
  for (final file in noteFiles) {
    final locale = file.uri.pathSegments.last.replaceAll('.json', '');
    final shape = _validateNotesFile(file, errors);
    if (shape != null) {
      shapes[locale] = shape;
    }
  }

  final template = shapes[_templateLocale];
  if (template == null) {
    errors.add(
      'Missing or invalid template release notes: '
      '${notesDirectory.path}/$_templateLocale.json',
    );
  } else {
    if (!template.containsKey(version)) {
      errors.add('Missing baked release note for $version.');
    }
    for (final entry in shapes.entries) {
      if (entry.key == _templateLocale) continue;
      for (final version in template.keys) {
        final bulletCount = entry.value[version];
        if (bulletCount == null) {
          errors.add('${entry.key}.json is missing version $version.');
        } else if (bulletCount != template[version]) {
          errors.add(
            '${entry.key}.json has $bulletCount bullets for $version, '
            'expected ${template[version]}.',
          );
        }
      }
      for (final version in entry.value.keys) {
        if (!template.containsKey(version)) {
          errors.add(
            '${entry.key}.json has version $version '
            'not present in $_templateLocale.json.',
          );
        }
      }
    }
  }

  _validateShellArbKeys(arbDirectory, errors);
  return ReleaseNotesValidationResult(errors);
}

/// Returns version -> bullet count, or null if the file is unusable.
Map<String, int>? _validateNotesFile(File file, List<String> errors) {
  final name = file.uri.pathSegments.last;
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } catch (error) {
    errors.add('Unable to read $name: $error');
    return null;
  }
  if (decoded is! Map<String, dynamic> || decoded['notes'] is! List) {
    errors.add('$name must be an object with a "notes" list.');
    return null;
  }

  final shape = <String, int>{};
  var previous = ReleaseVersion.tryParse('0.0.0')!;
  for (final note in decoded['notes'] as List) {
    if (note is! Map<String, dynamic>) {
      errors.add('$name has a note that is not an object.');
      continue;
    }
    final version = note['version'];
    if (version is! String || ReleaseVersion.tryParse(version) == null) {
      errors.add('$name has a note with an invalid version: $version');
      continue;
    }
    if (shape.containsKey(version)) {
      errors.add('$name has a duplicate note for $version.');
      continue;
    }
    final parsed = ReleaseVersion.tryParse(version)!;
    if (parsed.compareTo(previous) < 0) {
      errors.add('$name notes must be sorted by version.');
    }
    previous = parsed;

    for (final field in const ['title', 'intro']) {
      final value = note[field];
      if (value is! String || value.trim().isEmpty) {
        errors.add('$name $version is missing "$field".');
      }
    }

    final bullets = note['bullets'];
    if (bullets is! List || bullets.isEmpty) {
      errors.add('$name $version must have non-empty "bullets".');
      shape[version] = 0;
      continue;
    }
    for (final bullet in bullets) {
      if (bullet is! Map<String, dynamic> ||
          bullet['text'] is! String ||
          (bullet['text'] as String).trim().isEmpty) {
        errors.add('$name $version has a bullet without "text".');
        continue;
      }
      final icon = bullet['icon'];
      if (icon != null && !releaseNoteValidatorIconNames.contains(icon)) {
        errors.add('$name $version uses unknown icon "$icon".');
      }
    }
    shape[version] = bullets.length;
  }
  return shape;
}

void _validateShellArbKeys(Directory arbDirectory, List<String> errors) {
  if (!arbDirectory.existsSync()) {
    errors.add('Missing ARB directory: ${arbDirectory.path}');
    return;
  }
  final arbFiles =
      arbDirectory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.arb'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (arbFiles.isEmpty) {
    errors.add('No ARB files found in ${arbDirectory.path}.');
    return;
  }
  for (final file in arbFiles) {
    final Set<String> keys;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        errors.add('${file.path} is not a JSON object.');
        continue;
      }
      keys = decoded.keys.where((key) => !key.startsWith('@')).toSet();
    } catch (error) {
      errors.add('Unable to read ${file.path}: $error');
      continue;
    }
    for (final key in releaseNotesShellLocalizationKeys) {
      if (!keys.contains(key)) {
        errors.add('${file.path} is missing localization key "$key".');
      }
    }
  }
}
