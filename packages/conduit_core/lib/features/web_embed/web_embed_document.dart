/// Documents for previewing model-generated HTML and SVG in a WebView.
///
/// A trust boundary: the source is model output or a tool's result, and the
/// WebView runs its scripts, so the documents are composed here where the
/// rules live in one tested place.
///
/// [wrapSandboxedHtmlDocument] and [wrapSandboxedRemoteDocument] wrap the
/// content in a `sandbox="allow-scripts allow-forms allow-popups"` iframe,
/// inline in `srcdoc` or remote in `src`, for flutter_inappwebview.
library;

import 'dart:convert';

// ---------------------------------------------------------------------------
// Sizes.
// ---------------------------------------------------------------------------

/// The embed's height before the content reports one.
const double kWebEmbedDefaultHeight = 360.0;

/// The loading and fallback card's height.
const double kWebEmbedFallbackHeight = 160.0;

/// Reported heights are clamped into [kWebEmbedMinHeight],
/// [kWebEmbedMaxHeight].
const double kWebEmbedMinHeight = 220.0;
const double kWebEmbedMaxHeight = 900.0;

// ---------------------------------------------------------------------------
// Sources.
// ---------------------------------------------------------------------------

/// Whether [source] is a remote URL (`http://`, `https://` or `//`) rather
/// than inline HTML.
bool isRemoteWebEmbedSource(String source) {
  final raw = source.trim();
  return raw.startsWith('http://') ||
      raw.startsWith('https://') ||
      raw.startsWith('//');
}

/// The remote URL [source] names, with `//` resolved to https, or null when
/// it is not a remote URL or does not parse.
Uri? resolveRemoteWebEmbedUri(String source) {
  if (!isRemoteWebEmbedSource(source)) return null;
  return Uri.tryParse(source.startsWith('//') ? 'https:$source' : source);
}

// ---------------------------------------------------------------------------
// Escaping.
// ---------------------------------------------------------------------------

/// [value] as a JSON string literal that cannot close a `<script>` element
/// or start markup inside one.
String jsonForInlineScript(String value) {
  return jsonEncode(value)
      .replaceAll('&', r'\u0026')
      .replaceAll('<', r'\u003C')
      .replaceAll('>', r'\u003E');
}

/// [value] escaped for a double- or single-quoted HTML attribute.
String escapeHtmlAttribute(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

/// `window.args = <json>;` for non-blank [argsText], else empty.
String webEmbedInlineArgumentsScript(String argsText) {
  return argsText.trim().isEmpty
      ? ''
      : 'window.args = ${jsonForInlineScript(argsText)};';
}

// ---------------------------------------------------------------------------
// Documents (flutter_inappwebview).
// ---------------------------------------------------------------------------

/// The Flutter app's user script for every frame: reports the frame's height
/// to its parent. It reaches remote frames too, so it never carries tool
/// arguments.
const String webEmbedAllFrameBootstrapScript = '''
  (() => {
    const reportHeight = () => {
      const body = document.body;
      const html = document.documentElement;
      const height = Math.ceil(Math.max(
        body?.scrollHeight || 0,
        body?.offsetHeight || 0,
        html?.clientHeight || 0,
        html?.scrollHeight || 0,
        html?.offsetHeight || 0
      ));
      parent.postMessage({ type: 'conduit-embed-height', height }, '*');
    };

    window.addEventListener('load', reportHeight);
    if (typeof ResizeObserver !== 'undefined') {
      const observer = new ResizeObserver(reportHeight);
      const observeDocument = () => {
        if (document.documentElement) observer.observe(document.documentElement);
        if (document.body) observer.observe(document.body);
      };
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', observeDocument, { once: true });
      } else {
        observeDocument();
      }
    }
    setTimeout(reportHeight, 0);
    setTimeout(reportHeight, 250);
    setTimeout(reportHeight, 1000);
  })();
''';

/// The arguments bootstrap plus [webEmbedAllFrameBootstrapScript].
String webEmbedFrameBootstrapScript(String argsText) {
  return '''
${webEmbedInlineArgumentsScript(argsText)}
$webEmbedAllFrameBootstrapScript
''';
}

/// The Flutter app's document for inline HTML: [source] (with the arguments
/// script after its `<head>` or `<html>`) in a sandboxed srcdoc iframe.
String wrapSandboxedHtmlDocument(
  String source, {
  String argsText = '',
  bool fillAvailableHeight = false,
}) {
  final sandboxedSource = _injectSandboxBootstrap(source, argsText: argsText);
  final encodedSource = escapeHtmlAttribute(sandboxedSource);
  return _wrapSandboxedFrameDocument(
    sourceAttribute: 'srcdoc="$encodedSource"',
    fillAvailableHeight: fillAvailableHeight,
  );
}

/// The Flutter app's document for a remote embed URL.
String wrapSandboxedRemoteDocument(
  Uri source, {
  bool fillAvailableHeight = false,
}) {
  final encodedSource = escapeHtmlAttribute(source.toString());
  return _wrapSandboxedFrameDocument(
    sourceAttribute: 'src="$encodedSource"',
    fillAvailableHeight: fillAvailableHeight,
  );
}

String _wrapSandboxedFrameDocument({
  required String sourceAttribute,
  required bool fillAvailableHeight,
}) {
  return '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <style>
      html, body {
        margin: 0;
        padding: 0;
        background: transparent;
        width: 100%;
      }
      #embed-frame {
        display: block;
        width: 100%;
        height: ${fillAvailableHeight ? '100vh' : '${kWebEmbedDefaultHeight}px'};
        min-height: ${kWebEmbedMinHeight}px;
        border: 0;
        background: transparent;
      }
    </style>
    <script>
      (() => {
        const minHeight = $kWebEmbedMinHeight;
        const maxHeight = $kWebEmbedMaxHeight;
        const fillAvailableHeight = $fillAvailableHeight;
        window.addEventListener('message', (event) => {
          const data = event.data || {};
          const frame = document.getElementById('embed-frame');
          if (!frame || event.source !== frame.contentWindow) return;

          if (data.type !== 'conduit-embed-height') return;

          const height = Number(data.height);
          if (!Number.isFinite(height) || height <= 0) return;

          if (fillAvailableHeight) return;

          const clamped = Math.min(Math.max(height, minHeight), maxHeight);
          frame.style.height = `\${clamped}px`;
        });
      })();
    </script>
  </head>
  <body>
    <iframe
      id="embed-frame"
      sandbox="allow-scripts allow-forms allow-popups"
      referrerpolicy="no-referrer"
      $sourceAttribute
    ></iframe>
  </body>
</html>
''';
}

String _injectSandboxBootstrap(String source, {required String argsText}) {
  final argumentsScript = webEmbedInlineArgumentsScript(argsText);
  if (argumentsScript.isEmpty) {
    return source;
  }
  final bootstrap =
      '''
<script>
$argumentsScript
</script>
''';

  final headMatch = RegExp(
    r'<head\b[^>]*>',
    caseSensitive: false,
  ).firstMatch(source);
  if (headMatch != null) {
    return source.replaceRange(headMatch.end, headMatch.end, bootstrap);
  }

  final htmlMatch = RegExp(
    r'<html\b[^>]*>',
    caseSensitive: false,
  ).firstMatch(source);
  if (htmlMatch != null) {
    return source.replaceRange(htmlMatch.end, htmlMatch.end, bootstrap);
  }

  return '$bootstrap$source';
}
