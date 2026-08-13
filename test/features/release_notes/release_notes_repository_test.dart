import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/release_notes/data/release_notes_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every bundled release-notes asset parses through the app parser', () {
    final files =
        Directory('assets/release_notes')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    check(files).isNotEmpty();
    for (final file in files) {
      final notes = parseReleaseNotes(file.readAsStringSync());
      check(because: file.path, notes).isNotEmpty();
      for (final note in notes) {
        check(
          because: file.path,
          note.bulletIcons.length,
        ).equals(note.bullets.length);
        check(
          because: file.path,
          note.bulletIconAssets.length,
        ).equals(note.bullets.length);
        check(
          because: '${file.path} should not include the local persistence card',
          note.bulletIcons.contains(Icons.storage_rounded),
        ).isFalse();
      }
    }
  });

  test('parser rejects a note without bullets', () {
    check(() => parseReleaseNotes('{"notes":[{"version":"1.0.0"}]}'))
        .throws<FormatException>();
  });

  test('parser rejects a non-string bullet icon with FormatException', () {
    check(
      () => parseReleaseNotes(
        '{"notes":[{"version":"1.0.0","title":"Title",'
        '"intro":"Intro","bullets":[{"text":"Bullet","icon":7}]}]}',
      ),
    ).throws<FormatException>();
  });
}
