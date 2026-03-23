import 'package:webview_flutter_plus/webview_flutter_plus.dart';

const _measureWebViewContentHeightScript = r'''
(() => {
  const body = document.body;
  const root = document.documentElement;
  const scrollingElement = document.scrollingElement;
  if (!body && !root && !scrollingElement) {
    return 0;
  }

  const bodyStyle = body ? window.getComputedStyle(body) : null;
  const marginTop = bodyStyle
      ? (parseFloat(bodyStyle.marginTop || '0') || 0)
      : 0;
  const marginBottom = bodyStyle
      ? (parseFloat(bodyStyle.marginBottom || '0') || 0)
      : 0;
  const heights = [
    body ? body.scrollHeight : 0,
    body ? body.offsetHeight : 0,
    body ? body.clientHeight : 0,
    root ? root.scrollHeight : 0,
    root ? root.offsetHeight : 0,
    root ? root.clientHeight : 0,
    scrollingElement ? scrollingElement.scrollHeight : 0,
    scrollingElement ? scrollingElement.clientHeight : 0
  ].filter((value) => Number.isFinite(value) && value > 0);

  if (!heights.length) {
    return 0;
  }

  return Math.ceil(Math.max.apply(null, heights) + marginTop + marginBottom);
})()
''';

/// Measures the rendered document height inside a WebView.
///
/// Returns `null` when the page is not ready yet or when the platform bridge
/// returns a value that cannot be parsed as a number.
Future<double?> measureWebViewContentHeight(
  WebViewControllerPlus controller,
) async {
  final result = await controller.runJavaScriptReturningResult(
    _measureWebViewContentHeightScript,
  );
  final rawValue = result.toString().trim();
  if (rawValue.isEmpty || rawValue == 'null' || rawValue == 'undefined') {
    return null;
  }

  final normalizedValue =
      rawValue.startsWith('"') && rawValue.endsWith('"') && rawValue.length >= 2
      ? rawValue.substring(1, rawValue.length - 1)
      : rawValue;

  return double.tryParse(normalizedValue);
}
