import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/shared/widgets/markdown/renderer/pdf_inline_view.dart';

void main() {
  group('PdfInlineView.isPdfLink', () {
    test('accepts PDF paths with query strings and fragments', () {
      expect(
        PdfInlineView.isPdfLink('https://example.com/reports/q1.pdf?token=abc'),
        isTrue,
      );
      expect(
        PdfInlineView.isPdfLink('https://example.com/reports/q1.PDF#page=2'),
        isTrue,
      );
    });

    test('rejects non-PDF paths and query-only PDF names', () {
      expect(
        PdfInlineView.isPdfLink('https://example.com/report.html'),
        isFalse,
      );
      expect(
        PdfInlineView.isPdfLink('https://example.com/download?file=q1.pdf'),
        isFalse,
      );
      expect(PdfInlineView.isPdfLink(''), isFalse);
    });
  });
}
