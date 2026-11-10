import 'package:conduit/features/chat/widgets/composer_overflow_menu.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('composerAttachmentGridRows', () {
    test('keeps every tile in one row when they all fit', () {
      // iPhone 17 Pro: 402 pt wide, 20 pt insets.
      expect(composerAttachmentGridRows(count: 5, availableWidth: 362), [5]);
      expect(composerAttachmentGridRows(count: 3, availableWidth: 362), [3]);
    });

    test('balances rows instead of leaving one tile alone', () {
      expect(composerAttachmentGridRows(count: 5, availableWidth: 300), [3, 2]);
      expect(composerAttachmentGridRows(count: 6, availableWidth: 362), [3, 3]);
      expect(composerAttachmentGridRows(count: 7, availableWidth: 300), [4, 3]);
    });

    test('never asks for a tile narrower than the minimum', () {
      for (final width in [180.0, 240.0, 300.0, 362.0, 600.0]) {
        final rows = composerAttachmentGridRows(
          count: 6,
          availableWidth: width,
        );
        final columns = rows.first;
        final tileWidth = (width - (columns - 1) * 8) / columns;
        expect(tileWidth, greaterThanOrEqualTo(62), reason: 'width $width');
        expect(rows.reduce((a, b) => a + b), 6);
      }
    });

    test('handles no tiles', () {
      expect(
        composerAttachmentGridRows(count: 0, availableWidth: 362),
        isEmpty,
      );
    });
  });
}
