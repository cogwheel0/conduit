import 'package:conduit_core/utils/webview_content_height.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:meta/meta.dart';

/// Measures the rendered document height inside a WebView.
///
/// The script and the parsing live in conduit_core.
///
/// Returns `null` when the page is not ready yet or when the platform bridge
/// returns a value that cannot be parsed as a number.
Future<double?> measureWebViewContentHeight(
  InAppWebViewController controller,
) async {
  final result = await controller.evaluateJavascript(
    source: measureWebViewContentHeightScript,
  );

  return parseMeasuredWebViewContentHeightResult(result);
}

@visibleForTesting
double? parseMeasuredWebViewContentHeightResultForTesting(Object? rawValue) {
  return parseMeasuredWebViewContentHeightResult(rawValue);
}

@visibleForTesting
double? selectMeasuredWebViewContentHeightForTesting(
  Map<String, Object?> metrics,
) {
  return selectMeasuredWebViewContentHeight(metrics);
}
