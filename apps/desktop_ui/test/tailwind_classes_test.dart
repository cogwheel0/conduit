@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// Guards the `classes:` strings the renderer hands to Tailwind.
///
/// Tailwind fails silently. An unrecognised utility is simply not emitted,
/// and a *recognised* one with a bad value is emitted as invalid CSS the
/// browser then drops -- so a typo here costs nothing at build time and
/// shows up as a screenshot with square corners. There is no linter for
/// this, because the class names are string literals in Dart.
void main() {
  late final List<({String path, String text})> sources;

  setUpAll(() {
    sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        // The generated string catalog is 60k lines of translations and
        // contains no markup.
        .where((file) => !file.path.contains('/l10n/'))
        .map((file) => (path: file.path, text: file.readAsStringSync()))
        .toList();
  });

  test('no v3 bare-variable arbitrary values', () {
    // `rounded-[--radius]` was valid in Tailwind v3 and is not in v4, which
    // emits `border-radius: --radius` -- a declaration the browser discards.
    // Every rounded corner in the app was square for exactly this reason.
    // v4 spells it `rounded-(--radius)`, but the plain `rounded` utility
    // already resolves to `--radius`, so that is what the renderer uses.
    final offenders = <String>[];
    final pattern = RegExp(r'[a-z0-9-]+-\[--[a-z0-9-]+\]');
    for (final source in sources) {
      for (final match in pattern.allMatches(source.text)) {
        offenders.add('${source.path}: ${match[0]}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Tailwind v4 reads `foo-[--bar]` as the literal value `--bar`. '
          'Use `foo-(--bar)`, or a utility that already resolves the '
          'variable.',
    );
  });

  test('every utility used is emitted into the bundle', () {
    // The built stylesheet is the artifact that matters: a class that
    // survives review but never reaches app.css is a style that silently
    // does nothing.
    final bundle = File('web/app.css');
    if (!bundle.existsSync()) {
      markTestSkipped('run scripts/build-ui.mjs first');
      return;
    }
    final css = bundle.readAsStringSync();
    // Spot-check the utilities this app leans on that are not obvious --
    // the ones a reviewer would not think to look for.
    for (final utility in <String>[
      'sr-only',
      'rounded',
      'shrink-0',
      'min-w-0',
    ]) {
      expect(
        css,
        contains('.${utility.replaceAll('/', r'\/')}'),
        reason: '`$utility` is used by the renderer but is not in app.css',
      );
    }
  });
}
