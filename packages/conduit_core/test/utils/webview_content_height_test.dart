import 'package:checks/checks.dart';
import 'package:conduit_core/utils/webview_content_height.dart';
import 'package:test/test.dart';

void main() {
  group('selectMeasuredWebViewContentHeight', () {
    test('prefers content height over viewport-sized metrics', () {
      final measuredHeight = selectMeasuredWebViewContentHeight({
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

      check(measuredHeight).equals(422);
    });

    test('falls back to document heights when body metrics are missing', () {
      final measuredHeight = selectMeasuredWebViewContentHeight({
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

      check(measuredHeight).equals(640);
    });

    test(
      'takes the document when it is taller than the body and the viewport',
      () {
        final measuredHeight = selectMeasuredWebViewContentHeight({
          'bodyScrollHeight': 300,
          'rootScrollHeight': 900,
          'rootClientHeight': 500,
        });

        check(measuredHeight).equals(900);
      },
    );

    test('adds the body margins and rounds up', () {
      final measuredHeight = selectMeasuredWebViewContentHeight({
        'bodyScrollHeight': 100.2,
        'marginTop': 8,
        'marginBottom': 8,
      });

      check(measuredHeight).equals(117);
    });

    test('uses the viewport only when nothing else is measured', () {
      final measuredHeight = selectMeasuredWebViewContentHeight({
        'rootClientHeight': 480,
      });

      check(measuredHeight).equals(480);
    });

    test('reads numeric strings and ignores junk', () {
      check(selectMeasuredWebViewContentHeight({'bodyScrollHeight': ' 250 '}))
          .equals(250);
      check(selectMeasuredWebViewContentHeight({'bodyScrollHeight': 'tall'}))
          .isNull();
    });

    test('is null when every metric is zero', () {
      check(
        selectMeasuredWebViewContentHeight({
          'bodyScrollHeight': 0,
          'rootScrollHeight': 0,
        }),
      ).isNull();
    });
  });

  group('parseMeasuredWebViewContentHeightResult', () {
    test('parses quoted json bridge results', () {
      final measuredHeight = parseMeasuredWebViewContentHeightResult(
        '"{\\"bodyOffsetHeight\\":420,\\"rootClientHeight\\":1731}"',
      );

      check(measuredHeight).equals(420);
    });

    test('parses a json object string and a decoded map', () {
      check(parseMeasuredWebViewContentHeightResult('{"bodyScrollHeight":333}'))
          .equals(333);
      check(parseMeasuredWebViewContentHeightResult({'bodyScrollHeight': 334}))
          .equals(334);
    });

    test('parses plain numbers', () {
      check(parseMeasuredWebViewContentHeightResult(412)).equals(412);
      check(parseMeasuredWebViewContentHeightResult('412.5')).equals(412.5);
    });

    test('is null while the page is not ready', () {
      check(parseMeasuredWebViewContentHeightResult(null)).isNull();
      check(parseMeasuredWebViewContentHeightResult('null')).isNull();
      check(parseMeasuredWebViewContentHeightResult('"null"')).isNull();
      check(parseMeasuredWebViewContentHeightResult('undefined')).isNull();
      check(parseMeasuredWebViewContentHeightResult('  ')).isNull();
    });

    test('is null for a value it cannot read', () {
      check(parseMeasuredWebViewContentHeightResult('not json')).isNull();
      check(parseMeasuredWebViewContentHeightResult(true)).isNull();
    });
  });

  test('the script measures the body and the document', () {
    check(measureWebViewContentHeightScript)
      ..contains('bodyScrollHeight')
      ..contains('scrollingClientHeight')
      ..contains('marginBottom');
  });
}
