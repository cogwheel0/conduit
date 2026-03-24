import 'package:conduit/shared/widgets/webview_content_height.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefers content height over viewport-sized metrics', () {
    final measuredHeight = selectMeasuredWebViewContentHeightForTesting({
      'bodyScrollHeight': 422,
      'bodyOffsetHeight': 420,
      'bodyClientHeight': 420,
      'rootScrollHeight': 1731,
      'rootOffsetHeight': 1731,
      'rootClientHeight': 1731,
      'scrollingScrollHeight': 1731,
      'scrollingClientHeight': 1731,
      'marginTop': 0,
      'marginBottom': 0,
    });

    expect(measuredHeight, 422);
  });

  test('falls back to document heights when body metrics are missing', () {
    final measuredHeight = selectMeasuredWebViewContentHeightForTesting({
      'bodyScrollHeight': 0,
      'bodyOffsetHeight': 0,
      'bodyClientHeight': 0,
      'rootScrollHeight': 640,
      'rootOffsetHeight': 636,
      'rootClientHeight': 812,
      'scrollingScrollHeight': 640,
      'scrollingClientHeight': 812,
      'marginTop': 0,
      'marginBottom': 0,
    });

    expect(measuredHeight, 640);
  });

  test('parses quoted json bridge results', () {
    final measuredHeight = parseMeasuredWebViewContentHeightResultForTesting(
      '"{\\"bodyOffsetHeight\\":420,\\"rootClientHeight\\":1731}"',
    );

    expect(measuredHeight, 420);
  });
}
