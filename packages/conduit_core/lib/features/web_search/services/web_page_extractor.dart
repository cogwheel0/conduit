import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:conduit_core/features/web_search/services/web_page_fetcher.dart';

/// Readable text extracted from a fetched page.
final class ExtractedWebPage {
  const ExtractedWebPage({required this.title, required this.text});

  final String title;

  /// Markdown-flavoured plain text: headings, list items and code blocks
  /// keep their structure; navigation, ads and scripts are dropped.
  final String text;
}

/// Extracts the readable part of [page].
ExtractedWebPage extractReadableText(FetchedWebPage page) {
  if (page.contentType != 'text/html' &&
      page.contentType != 'application/xhtml+xml') {
    return ExtractedWebPage(title: '', text: _tidy(page.body));
  }
  final document = html_parser.parse(page.body);
  final title = _title(document);
  _removeChrome(document);
  final root = _contentRoot(document);
  if (root == null) return ExtractedWebPage(title: title, text: '');
  final buffer = _TextBuffer();
  _render(root, buffer);
  return ExtractedWebPage(title: title, text: _tidy(buffer.toString()));
}

String _title(Document document) {
  final candidates = [
    document.querySelector('meta[property="og:title"]')?.attributes['content'],
    document.querySelector('title')?.text,
    document.querySelector('h1')?.text,
  ];
  for (final candidate in candidates) {
    final text = _collapse(candidate ?? '');
    if (text.isNotEmpty) return text;
  }
  return '';
}

const _chromeSelectors = [
  'script',
  'style',
  'noscript',
  'template',
  'svg',
  'canvas',
  'iframe',
  'object',
  'embed',
  'form',
  'button',
  'select',
  'textarea',
  'nav',
  'header',
  'footer',
  'aside',
  'dialog',
  '[hidden]',
  '[aria-hidden="true"]',
  '[role="navigation"]',
  '[role="banner"]',
  '[role="contentinfo"]',
  '[role="complementary"]',
  '[role="dialog"]',
];

/// Class or id tokens that mark page furniture rather than content.
final _chromeToken = RegExp(
  r'(^|[-_])(cookie|consent|gdpr|advert|ads?|sponsor|sidebar|newsletter|'
  r'subscribe|social|share|related|comments?|promo|popup|modal|breadcrumbs?|'
  r'skip-link)($|[-_])',
);

void _removeChrome(Document document) {
  for (final selector in _chromeSelectors) {
    for (final element in document.querySelectorAll(selector)) {
      // Some sites wrap everything in a <header> or <form>; never throw away
      // the element that holds the article itself.
      if (_holdsMainContent(element)) continue;
      element.remove();
    }
  }
  // Class names are a weaker signal than tags: a `layout-has-sidebar`
  // wrapper can hold the whole article. Only drop elements that hold a minor
  // share of the page's text.
  final pageTextLength = document.body?.text.length ?? 0;
  for (final element in document.querySelectorAll('[class], [id]')) {
    if (element.parent == null || _holdsMainContent(element)) continue;
    final tokens = [
      ...element.classes,
      if (element.id.isNotEmpty) element.id,
    ].map((token) => token.toLowerCase());
    if (!tokens.any(_chromeToken.hasMatch)) continue;
    if (element.text.length * 2 > pageTextLength) continue;
    element.remove();
  }
}

bool _holdsMainContent(Element element) {
  final tag = element.localName;
  if (tag == 'body' || tag == 'html' || tag == 'main' || tag == 'article') {
    return true;
  }
  return element.querySelector('main, article, [role="main"]') != null;
}

Element? _contentRoot(Document document) {
  final body = document.body;
  if (body == null) return null;
  final candidates = document.querySelectorAll('article, main, [role="main"]');
  Element? best;
  var bestLength = 0;
  for (final candidate in candidates) {
    final length = _collapse(candidate.text).length;
    if (length > bestLength) {
      best = candidate;
      bestLength = length;
    }
  }
  // A short <article> is usually a teaser card, not the page's content.
  return best != null && bestLength >= 200 ? best : body;
}

const _blockTags = {
  'address',
  'article',
  'blockquote',
  'dd',
  'details',
  'div',
  'dl',
  'dt',
  'figcaption',
  'figure',
  'hr',
  'li',
  'main',
  'ol',
  'p',
  'section',
  'summary',
  'table',
  'tbody',
  'thead',
  'tr',
  'ul',
};

void _render(Node node, _TextBuffer out) {
  if (node is Text) {
    out.inline(node.text);
    return;
  }
  if (node is! Element) return;
  final tag = node.localName ?? '';
  switch (tag) {
    case 'br':
      out.newline();
      return;
    case 'img':
      return;
    case 'pre':
      out.block();
      out.raw('```\n${node.text.trimRight()}\n```');
      out.block();
      return;
    case 'code':
      out.inline('`${_collapse(node.text)}`');
      return;
    case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
      final text = _collapse(node.text);
      if (text.isEmpty) return;
      out.block();
      out.raw('${'#' * int.parse(tag.substring(1))} $text');
      out.block();
      return;
    case 'li':
      out.newline();
      out.raw('- ');
      for (final child in node.nodes) {
        _render(child, out);
      }
      out.newline();
      return;
    case 'td' || 'th':
      for (final child in node.nodes) {
        _render(child, out);
      }
      out.inline(' | ');
      return;
  }
  final isBlock = _blockTags.contains(tag);
  if (isBlock) out.block();
  for (final child in node.nodes) {
    _render(child, out);
  }
  if (isBlock) out.block();
}

/// Accumulates rendered text while collapsing inline whitespace.
final class _TextBuffer {
  final StringBuffer _buffer = StringBuffer();
  bool _pendingSpace = false;
  bool _atLineStart = true;

  void inline(String text) {
    if (text.isEmpty) return;
    final collapsed = _collapse(text);
    if (collapsed.isEmpty) {
      _pendingSpace = true;
      return;
    }
    if ((_pendingSpace || text.startsWith(_space)) && !_atLineStart) {
      _buffer.write(' ');
    }
    _buffer.write(collapsed);
    _pendingSpace = _space.hasMatch(text[text.length - 1]);
    _atLineStart = false;
  }

  /// Writes [text] verbatim; a trailing space or newline counts as a line
  /// start so the next inline text doesn't gain a leading space.
  void raw(String text) {
    _buffer.write(text);
    _pendingSpace = false;
    _atLineStart = text.endsWith('\n') || text.endsWith(' ');
  }

  void newline() => raw('\n');

  void block() => raw('\n\n');

  @override
  String toString() => _buffer.toString();
}

final _space = RegExp(r'\s');
final _whitespace = RegExp(r'\s+');

String _collapse(String text) => text.replaceAll(_whitespace, ' ').trim();

/// Trims each line and limits blank runs to one empty line.
String _tidy(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((line) => line.trimRight())
      .toList();
  final out = StringBuffer();
  var blankRun = 0;
  var inFence = false;
  for (final line in lines) {
    if (line.trimLeft().startsWith('```')) inFence = !inFence;
    final trimmed = inFence ? line : line.trim();
    if (trimmed.isEmpty) {
      blankRun++;
      if (blankRun > 1) continue;
    } else {
      blankRun = 0;
    }
    out.writeln(trimmed);
  }
  return out.toString().trim();
}
