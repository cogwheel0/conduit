/// Measuring a rendered document's height inside a WebView: the script to
/// evaluate and the parsing of what it returns.
///
/// The app evaluates [measureWebViewContentHeightScript] on its WebView
/// controller and hands the raw result to
/// [parseMeasuredWebViewContentHeightResult].
library;

import 'dart:convert';

const measureWebViewContentHeightScript = r'''
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

/// Parses the result of [measureWebViewContentHeightScript] into a height in
/// logical pixels.
///
/// Returns `null` when the page is not ready yet or when the platform bridge
/// returns a value that cannot be parsed as a number.
double? parseMeasuredWebViewContentHeightResult(Object? rawValue) {
  dynamic decoded = rawValue;

  if (decoded == null) {
    return null;
  }

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
    return selectMeasuredWebViewContentHeight(decoded);
  }

  return null;
}

/// Picks the content height out of the script's metrics: the body's when it
/// is the tallest thing, the document's when the body is shorter and the
/// viewport is not just the document itself, plus the body margins.
double? selectMeasuredWebViewContentHeight(Map<dynamic, dynamic> metrics) {
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
