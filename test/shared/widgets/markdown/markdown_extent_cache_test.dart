import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/markdown/markdown_extent_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(debugResetMarkdownExtentCache);
  tearDown(debugResetMarkdownExtentCache);

  test('records and resolves heights per width and text scale', () {
    final cache = MarkdownExtentCache.instance;
    cache.record(
      'body',
      maxWidth: 320,
      textScaledHundred: 100,
      height: 240.5,
    );

    check(
      cache.heightFor('body', maxWidth: 320, textScaledHundred: 100),
    ).equals(240.5);
    check(
      cache.heightFor('body', maxWidth: 280, textScaledHundred: 100),
    ).isNull();
    check(
      cache.heightFor('body', maxWidth: 320, textScaledHundred: 130),
    ).isNull();
    check(
      cache.heightFor('other', maxWidth: 320, textScaledHundred: 100),
    ).isNull();
  });

  test('hasLikelyCurrentExtent tracks recently recorded geometries', () {
    final cache = MarkdownExtentCache.instance;
    check(cache.hasLikelyCurrentExtent('body')).isFalse();

    cache.record('body', maxWidth: 320, textScaledHundred: 100, height: 100);
    check(cache.hasLikelyCurrentExtent('body')).isTrue();
    check(cache.hasLikelyCurrentExtent('other')).isFalse();
  });

  test('a burst of new geometries displaces stale ones', () {
    final cache = MarkdownExtentCache.instance;
    cache.record('body', maxWidth: 320, textScaledHundred: 100, height: 100);
    check(cache.hasLikelyCurrentExtent('body')).isTrue();

    // Rotation/text-scale changes produce fresh geometries; once the ring
    // cycles past the old one, entries recorded there stop matching.
    for (var index = 0; index < 8; index += 1) {
      cache.record(
        'other-$index',
        maxWidth: 600.0 + index,
        textScaledHundred: 100,
        height: 50,
      );
    }
    check(cache.hasLikelyCurrentExtent('body')).isFalse();
  });

  test('ignores non-finite and non-positive heights', () {
    final cache = MarkdownExtentCache.instance;
    cache.record('body', maxWidth: 320, textScaledHundred: 100, height: 0);
    cache.record(
      'body',
      maxWidth: 320,
      textScaledHundred: 100,
      height: double.infinity,
    );
    check(cache.debugLength).equals(0);
    check(cache.hasLikelyCurrentExtent('body')).isFalse();
  });

  test('re-recording moves an entry instead of duplicating it', () {
    final cache = MarkdownExtentCache.instance;
    cache.record('body', maxWidth: 320, textScaledHundred: 100, height: 100);
    cache.record('body', maxWidth: 320, textScaledHundred: 100, height: 140);
    check(cache.debugLength).equals(1);
    check(
      cache.heightFor('body', maxWidth: 320, textScaledHundred: 100),
    ).equals(140);
  });
}
