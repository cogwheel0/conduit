import 'package:checks/checks.dart';
import 'package:conduit_core/features/release_notes/models/release_note.dart';
import 'package:conduit_core/features/release_notes/models/release_version.dart';
import 'package:conduit_core/features/release_notes/services/release_notes_service.dart';
import 'package:test/test.dart';

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

  test('an unparseable installed version does nothing', () {
    final decision = service.evaluate(
      currentVersion: 'dev',
      lastSeenVersion: '3.3.1',
      notes: [note('3.3.2')],
    );

    check(decision.type).equals(ReleaseNotesDecisionType.none);
    check(decision.currentVersion).equals('dev');
  });

  test('older version shows all baked notes since last seen version', () {
    final decision = service.evaluate(
      currentVersion: '3.4.0',
      lastSeenVersion: '3.3.1',
      notes: [note('3.4.0'), note('3.3.2'), note('3.3.1')],
    );

    check(decision.type).equals(ReleaseNotesDecisionType.show);
    check(decision.previousVersion).equals('3.3.1');
    check(decision.notes.map((release) => release.version))
        .deepEquals(['3.3.2', '3.4.0']);
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

  test('notes newer than the installed version are left out', () {
    final decision = service.evaluate(
      currentVersion: '3.3.2',
      lastSeenVersion: '3.3.0',
      notes: [note('3.3.1'), note('3.4.0')],
    );

    check(decision.type).equals(ReleaseNotesDecisionType.show);
    check(decision.notes.map((release) => release.version))
        .deepEquals(['3.3.1']);
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

  group('latestBundledReleaseNotesForVersion', () {
    test('picks the latest bundled note at or before current', () {
      final notes = latestBundledReleaseNotesForVersion(
        currentVersion: '3.3.3',
        notes: [note('3.3.1'), note('3.3.2'), note('3.4.0')],
      );

      check(notes.map((release) => release.version)).deepEquals(['3.3.2']);
    });

    test('omits notes newer than the installed app version', () {
      final notes = latestBundledReleaseNotesForVersion(
        currentVersion: '3.3.1',
        notes: [note('3.3.2')],
      );

      check(notes).isEmpty();
    });

    test('takes the newest note when the installed version is unparseable', () {
      final notes = latestBundledReleaseNotesForVersion(
        currentVersion: 'dev',
        notes: [note('3.3.2'), note('3.4.0'), note('3.3.1')],
      );

      check(notes.map((release) => release.version)).deepEquals(['3.4.0']);
    });

    test('returns nothing for no notes', () {
      check(
        latestBundledReleaseNotesForVersion(
          currentVersion: '3.3.2',
          notes: const <ReleaseNote>[],
        ),
      ).isEmpty();
    });
  });
}
