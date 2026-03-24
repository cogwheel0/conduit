import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter_plus/webview_flutter_plus.dart';

const _measureWebViewContentHeightScript = r'''
(() => {
  const body = document.body;
  const root = document.documentElement;
  const scrollingElement = document.scrollingElement;
  if (!body && !root && !scrollingElement) {
    return JSON.stringify(null);
  }

  const finiteOrZero = (value) => Number.isFinite(value) ? value : 0;
  const bodyStyle = body ? window.getComputedStyle(body) : null;
  return JSON.stringify({
    bodyScrollHeight: finiteOrZero(body ? body.scrollHeight : 0),
    bodyOffsetHeight: finiteOrZero(body ? body.offsetHeight : 0),
    bodyClientHeight: finiteOrZero(body ? body.clientHeight : 0),
    rootScrollHeight: finiteOrZero(root ? root.scrollHeight : 0),
    rootOffsetHeight: finiteOrZero(root ? root.offsetHeight : 0),
    rootClientHeight: finiteOrZero(root ? root.clientHeight : 0),
    scrollingScrollHeight: finiteOrZero(
      scrollingElement ? scrollingElement.scrollHeight : 0,
    ),
    scrollingOffsetHeight: finiteOrZero(
      scrollingElement ? scrollingElement.offsetHeight : 0,
    ),
    scrollingClientHeight: finiteOrZero(
      scrollingElement ? scrollingElement.clientHeight : 0,
    ),
    marginTop: finiteOrZero(
      bodyStyle ? parseFloat(bodyStyle.marginTop || '0') : 0,
    ),
    marginBottom: finiteOrZero(
      bodyStyle ? parseFloat(bodyStyle.marginBottom || '0') : 0,
    ),
  });
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

  return _parseMeasuredWebViewContentHeightResult(result.toString());
}

double? _parseMeasuredWebViewContentHeightResult(String rawValue) {
  dynamic decoded = rawValue.trim();

  for (var i = 0; i < 2; i++) {
    if (decoded is! String) {
      break;
    }

    final trimmed = decoded.trim();
    if (trimmed.isEmpty || trimmed == 'null' || trimmed == 'undefined') {
      return null;
    }

    try {
      decoded = jsonDecode(trimmed);
      continue;
    } on FormatException {
      return double.tryParse(trimmed);
    }
  }

  if (decoded is num) {
    return decoded.toDouble();
  }

  if (decoded is Map) {
    return _selectMeasuredWebViewContentHeight(decoded);
  }

  return null;
}

double? _selectMeasuredWebViewContentHeight(Map<dynamic, dynamic> metrics) {
  double readMetric(String key) {
    final value = metrics[key];
    return switch (value) {
      final num number => number.toDouble(),
      final String text => double.tryParse(text.trim()) ?? 0,
      _ => 0,
    };
  }

  double? maxPositive(Iterable<double> values) {
    final positiveValues = values.where((value) => value > 0).toList();
    if (positiveValues.isEmpty) {
      return null;
    }

    return positiveValues.reduce((left, right) => left > right ? left : right);
  }

  final bodyHeight = maxPositive([
    readMetric('bodyScrollHeight'),
    readMetric('bodyOffsetHeight'),
    readMetric('bodyClientHeight'),
  ]);
  final documentHeight = maxPositive([
    readMetric('rootScrollHeight'),
    readMetric('rootOffsetHeight'),
    readMetric('scrollingScrollHeight'),
    readMetric('scrollingOffsetHeight'),
  ]);
  final viewportHeight = maxPositive([
    readMetric('rootClientHeight'),
    readMetric('scrollingClientHeight'),
  ]);
  final marginHeight = readMetric('marginTop') + readMetric('marginBottom');

  final viewportMatchesDocument =
      documentHeight != null &&
      viewportHeight != null &&
      (documentHeight - viewportHeight).abs() <= 1;

  final selectedHeight = switch ((bodyHeight, documentHeight)) {
    (final double body, final double document)
        when document > body && !viewportMatchesDocument =>
      document,
    (final double body, _) => body,
    (_, final double document) => document,
    _ => viewportHeight,
  };

  if (selectedHeight == null || selectedHeight <= 0) {
    return null;
  }

  return (selectedHeight + marginHeight).ceilToDouble();
}

@visibleForTesting
double? parseMeasuredWebViewContentHeightResultForTesting(String rawValue) {
  return _parseMeasuredWebViewContentHeightResult(rawValue);
}

@visibleForTesting
double? selectMeasuredWebViewContentHeightForTesting(
  Map<String, Object?> metrics,
) {
  return _selectMeasuredWebViewContentHeight(metrics);
}
