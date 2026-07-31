import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_notes_validator.dart';

void main() {
  late Directory tempDir;
  late Directory arbDir;
  late Directory notesDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'release-notes-validator-test',
    );
    arbDir = Directory('${tempDir.path}/l10n')..createSync();
    notesDir = Directory('${tempDir.path}/release_notes')..createSync();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  void writeArb(String name, Map<String, Object?> values) {
    File('${arbDir.path}/$name').writeAsStringSync(jsonEncode(values));
  }

  void writeNotes(String locale, Object document) {
    File(
      '${notesDir.path}/$locale.json',
    ).writeAsStringSync(jsonEncode(document));
  }

  Map<String, Object?> validArb() => {
    '@@locale': 'en',
    for (final key in releaseNotesShellLocalizationKeys) key: key,
  };

  Map<String, Object?> note(
    String version, {
    int bulletCount = 2,
    String? icon = 'local',
  }) => {
    'version': version,
    'title': 'Title $version',
    'intro': 'Intro $version',
    'bullets': [
      for (var i = 0; i < bulletCount; i++)
        {'text': 'Bullet $i', if (icon != null && i == 0) 'icon': icon},
    ],
  };

  ReleaseNotesValidationResult validate(String version) {
    return validateReleaseNotes(
      version: version,
      arbDirectory: arbDir,
      notesDirectory: notesDir,
    );
  }

  test('accepts matching notes across locales with shell keys', () {
    writeArb('app_en.arb', validArb());
    writeArb('app_de.arb', validArb());
    writeNotes('en', {
      'notes': [note('3.3.2'), note('4.0.0')],
    });
    writeNotes('de', {
      'notes': [note('3.3.2'), note('4.0.0')],
    });

    check(validate('4.0.0').errors).isEmpty();
  });

  test('fails when the target version has no baked note', () {
    writeArb('app_en.arb', validArb());
    writeNotes('en', {
      'notes': [note('3.3.2')],
    });

    check(
      validate('4.0.0').errors,
    ).contains('Missing baked release note for 4.0.0.');
  });

  test('fails when a locale is missing a version', () {
    writeArb('app_en.arb', validArb());
    writeArb('app_de.arb', validArb());
    writeNotes('en', {
      'notes': [note('3.3.2'), note('4.0.0')],
    });
    writeNotes('de', {
      'notes': [note('3.3.2')],
    });

    check(
      validate('4.0.0').errors,
    ).contains('de.json is missing version 4.0.0.');
  });

  test('fails when an ARB locale has no release-note JSON file', () {
    writeArb('app_en.arb', validArb());
    writeArb('app_de.arb', validArb());
    writeNotes('en', {
      'notes': [note('4.0.0')],
    });

    check(
      validate('4.0.0').errors,
    ).contains('Missing release-note JSON for ARB locale de.');
  });

  test('fails when release-note JSON has no matching ARB locale', () {
    writeArb('app_en.arb', validArb());
    writeNotes('en', {
      'notes': [note('4.0.0')],
    });
    writeNotes('de', {
      'notes': [note('4.0.0')],
    });

    check(
      validate('4.0.0').errors,
    ).contains('Missing ARB locale for release-note JSON de.json.');
  });

  test('fails when a locale has a different bullet count', () {
    writeArb('app_en.arb', validArb());
    writeArb('app_de.arb', validArb());
    writeNotes('en', {
      'notes': [note('4.0.0', bulletCount: 3)],
    });
    writeNotes('de', {
      'notes': [note('4.0.0', bulletCount: 2)],
    });

    check(
      validate('4.0.0').errors.single,
    ).contains('de.json has 2 bullets for 4.0.0, expected 3');
  });

  test('fails on unknown icon names and unsorted versions', () {
    writeArb('app_en.arb', validArb());
    writeNotes('en', {
      'notes': [note('4.0.0', icon: 'sparkle'), note('3.3.2')],
    });

    final errors = validate('4.0.0').errors;
    check(errors.any((e) => e.contains('unknown icon "sparkle"'))).isTrue();
    check(errors.any((e) => e.contains('sorted by version'))).isTrue();
  });

  test('fails when a locale carries a version en does not have', () {
    writeArb('app_en.arb', validArb());
    writeArb('app_de.arb', validArb());
    writeNotes('en', {
      'notes': [note('4.0.0')],
    });
    writeNotes('de', {
      'notes': [note('4.0.0'), note('4.1.0')],
    });

    check(
      validate('4.0.0').errors.single,
    ).contains('de.json has version 4.1.0');
  });

  test('fails when a locale ARB is missing a shell key', () {
    writeArb('app_en.arb', validArb()..remove('releaseNotesTitle'));
    writeNotes('en', {
      'notes': [note('4.0.0')],
    });

    check(validate('4.0.0').errors.single).contains('releaseNotesTitle');
  });
}
