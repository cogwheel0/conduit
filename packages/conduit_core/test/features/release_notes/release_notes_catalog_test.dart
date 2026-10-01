import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/release_notes/data/release_notes_catalog.dart';
import 'package:test/test.dart';

String _document({String version = '4.0.1', String? icon}) => jsonEncode({
  'notes': [
    {
      'version': version,
      'title': 'Title $version',
      'intro': 'Intro $version',
      'bullets': [
        {'text': 'First', 'icon': ?icon},
        {'text': 'Second'},
      ],
    },
  ],
});

void main() {
  group('localeCandidates', () {
    test('lists the script, then the country, then the language', () {
      check(
        ReleaseNotesCatalog.localeCandidates(
          languageCode: 'zh',
          scriptCode: 'Hant',
          countryCode: 'TW',
        ),
      ).deepEquals(['zh_Hant', 'zh_TW', 'zh']);
    });

    test('skips empty and missing parts', () {
      check(
        ReleaseNotesCatalog.localeCandidates(
          languageCode: 'de',
          scriptCode: '',
        ),
      ).deepEquals(['de']);
      check(
        ReleaseNotesCatalog.localeCandidates(
          languageCode: 'pt',
          countryCode: 'BR',
        ),
      ).deepEquals(['pt_BR', 'pt']);
    });
  });

  group('load', () {
    test('takes the most specific asset that exists', () async {
      final requested = <String>[];
      final catalog = ReleaseNotesCatalog(
        loadAsset: (path) async {
          requested.add(path);
          return path.endsWith('/zh.json') ? _document(version: '4.0.2') : null;
        },
      );

      final notes = await catalog.load(languageCode: 'zh', scriptCode: 'Hant');

      check(notes.single.version).equals('4.0.2');
      check(requested).deepEquals([
        'assets/release_notes/zh_Hant.json',
        'assets/release_notes/zh.json',
      ]);
    });

    test('falls back to English, then to nothing', () async {
      final english = ReleaseNotesCatalog(
        loadAsset: (path) async =>
            path == 'assets/release_notes/en.json' ? _document() : null,
      );
      check((await english.load(languageCode: 'sv')).single.version)
          .equals('4.0.1');

      final none = ReleaseNotesCatalog(loadAsset: (_) async => null);
      check(await none.load(languageCode: 'sv')).isEmpty();
    });

    test('a malformed document surfaces instead of falling through', () async {
      final catalog = ReleaseNotesCatalog(loadAsset: (_) async => '[]');
      await check(catalog.load(languageCode: 'en')).throws<FormatException>();
    });
  });

  group('parseReleaseNotes', () {
    test('keeps known icon names aligned with the bullets', () {
      final note = parseReleaseNotes(_document(icon: 'hermes')).single;

      check(note.bullets).deepEquals(['First', 'Second']);
      check(note.bulletIcons).deepEquals(['hermes', null]);
      check(note.iconNameForBullet(0)).equals('hermes');
      check(note.iconNameForBullet(1)).isNull();
      check(note.iconNameForBullet(5)).isNull();
    });

    test('drops an icon name it does not know', () {
      final note = parseReleaseNotes(_document(icon: 'sparkles')).single;

      check(note.bulletIcons).deepEquals([null, null]);
    });

    test('rejects a note without bullets', () {
      check(() => parseReleaseNotes('{"notes":[{"version":"1.0.0"}]}'))
          .throws<FormatException>();
    });

    test('rejects a non-string bullet icon', () {
      check(
        () => parseReleaseNotes(
          '{"notes":[{"version":"1.0.0","title":"Title",'
          '"intro":"Intro","bullets":[{"text":"Bullet","icon":7}]}]}',
        ),
      ).throws<FormatException>();
    });

    test('rejects a document that is not an object with notes', () {
      check(() => parseReleaseNotes('[]')).throws<FormatException>();
      check(() => parseReleaseNotes('{}')).throws<FormatException>();
    });

    test('rejects a missing title', () {
      check(
        () => parseReleaseNotes(
          '{"notes":[{"version":"1.0.0","intro":"Intro",'
          '"bullets":[{"text":"Bullet"}]}]}',
        ),
      ).throws<FormatException>();
    });
  });
}
