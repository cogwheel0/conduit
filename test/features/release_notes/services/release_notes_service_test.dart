import 'package:checks/checks.dart';
import 'package:conduit/features/release_notes/models/release_note.dart';
import 'package:conduit/features/release_notes/models/release_version.dart';
import 'package:conduit/features/release_notes/release_notes_presenter.dart';
import 'package:conduit/features/release_notes/services/release_notes_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = ReleaseNotesService();

  ReleaseNote note(String version) => ReleaseNote(
    version: version,
    title: 'Release $version',
    intro: 'Intro $version',
    bullets: ['Bullet $version'],
  );

  test('fresh install persists current version without showing notes', () {
    final decision = service.evaluate(
      currentVersion: '3.3.2',
      lastSeenVersion: null,
      notes: [note('3.3.2')],
    );

    check(decision.type).equals(ReleaseNotesDecisionType.persistOnly);
    check(decision.currentVersion).equals('3.3.2');
    check(decision.notes).isEmpty();
  });

  test('same version does nothing', () {
    final decision = service.evaluate(
      currentVersion: '3.3.2',
      lastSeenVersion: '3.3.2',
      notes: [note('3.3.2')],
    );

    check(decision.type).equals(ReleaseNotesDecisionType.none);
    check(decision.shouldPersist).isFalse();
  });

  test('older version shows all baked notes since last seen version', () {
    final decision = service.evaluate(
      currentVersion: '3.4.0',
      lastSeenVersion: '3.3.1',
      notes: [note('3.4.0'), note('3.3.2'), note('3.3.1')],
    );

    check(decision.type).equals(ReleaseNotesDecisionType.show);
    check(decision.previousVersion).equals('3.3.1');
    check(
      decision.notes.map((release) => release.version),
    ).deepEquals(['3.3.2', '3.4.0']);
  });

  test('missing baked note still advances current version', () {
    final decision = service.evaluate(
      currentVersion: '3.3.3',
      lastSeenVersion: '3.3.2',
      notes: [note('3.3.2')],
    );

    check(decision.type).equals(ReleaseNotesDecisionType.persistOnly);
    check(decision.currentVersion).equals('3.3.3');
  });

  test('invalid stored version is re-baselined without showing notes', () {
    final decision = service.evaluate(
      currentVersion: '3.3.2',
      lastSeenVersion: 'not-a-version',
      notes: [note('3.3.2')],
    );

    check(decision.type).equals(ReleaseNotesDecisionType.persistOnly);
  });

  test('version comparison is semantic, not lexical', () {
    final version310 = ReleaseVersion.parse('3.10.0');
    final version39 = ReleaseVersion.parse('3.9.0');

    check(version310.compareTo(version39)).isGreaterThan(0);
  });

  test('release versions reject leading zeroes', () {
    check(ReleaseVersion.tryParse('04.0.0')).isNull();
    check(ReleaseVersion.tryParse('4.00.0')).isNull();
    check(ReleaseVersion.tryParse('4.0.01')).isNull();
  });

  test(
    'manual presenter picks the latest bundled note at or before current',
    () {
      final notes = latestBundledReleaseNotesForVersion(
        currentVersion: '3.3.3',
        notes: [note('3.3.1'), note('3.3.2'), note('3.4.0')],
      );

      check(notes.map((release) => release.version)).deepEquals(['3.3.2']);
    },
  );

  test('manual presenter omits notes newer than the installed app version', () {
    final notes = latestBundledReleaseNotesForVersion(
      currentVersion: '3.3.1',
      notes: [note('3.3.2')],
    );

    check(notes).isEmpty();
  });
}
