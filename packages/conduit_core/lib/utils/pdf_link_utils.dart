import 'dart:collection';

import 'package:conduit_core/services/server_tls_http_client_factory.dart';

/// Markdown PDF links: which links preview as a PDF, what their card is
/// called, and where the bytes are fetched from, for the PDF views (pdfrx).

/// Whether [href] points at a PDF: its path, not its query, ends in `.pdf`.
bool isPdfLink(String href) {
  final trimmed = href.trim();
  if (trimmed.isEmpty) return false;

  final uri = Uri.tryParse(trimmed);
  final rawPath = uri?.path.isNotEmpty == true
      ? uri!.path
      : trimmed.split('?').first.split('#').first;
  return _decodeUriComponent(rawPath).toLowerCase().endsWith('.pdf');
}

/// The card title: the link label without a leading 📄, else the file name
/// from the URL, else [fallback].
String pdfTitle({
  required String? rawLabel,
  required String url,
  required String fallback,
}) {
  final label = (rawLabel ?? '')
      .replaceFirst(RegExp(r'^\s*\u{1F4C4}\s*', unicode: true), '')
      .trim();
  if (label.isNotEmpty && label != url.trim()) {
    return label;
  }

  final fileName = _fileNameFromUrl(url);
  if (fileName != null && fileName.isNotEmpty) {
    return fileName;
  }
  return fallback;
}

/// A file name for sharing [title]: letters, digits, spaces, `.`, `_`, `-`,
/// at most 80 characters, ending in `.pdf`.
String pdfShareFileName(String title) {
  var base = title
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s._\-]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (base.length > 80) base = base.substring(0, 80).trim();
  if (base.isEmpty) base = 'document';
  return base.toLowerCase().endsWith('.pdf') ? base : '$base.pdf';
}

/// Resolves a server-relative [url] against the selected server's
/// [baseUrl]; absolute URLs pass through.
String resolvePdfRequestUrl(String url, String? baseUrl) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return url;

  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.hasScheme) {
    return trimmed;
  }

  var baseUri = baseUrl == null
      ? null
      : ServerTlsHttpClientFactory.parseBaseUri(baseUrl);
  if (baseUri == null) {
    return trimmed;
  }

  if (trimmed.startsWith('/')) {
    return '${_baseUrlWithoutTrailingSlash(baseUri)}$trimmed';
  }

  if (!baseUri.path.endsWith('/')) {
    baseUri = baseUri.replace(path: '${baseUri.path}/');
  }

  return baseUri.resolveUri(uri).toString();
}

/// Height of a page rendered [width] wide; A4 proportions for a page that
/// reports no size.
double pdfHeightForWidth({
  required double pageWidth,
  required double pageHeight,
  required double width,
}) {
  if (pageWidth <= 0 || pageHeight <= 0) {
    return width * 1.414;
  }
  return width * pageHeight / pageWidth;
}

/// Width over height of a page; A4 portrait for a page that reports no size.
double pdfPageAspect({required double width, required double height}) {
  if (width <= 0 || height <= 0) {
    return 0.707;
  }
  return width / height;
}

/// Rendered page bitmaps held for a PDF viewer, most recently shown first,
/// evicting the least recently shown pages once [maxBytes] is exceeded. The
/// page just added is never evicted by its own insertion.
class PdfPageImageCache<T> {
  PdfPageImageCache({
    required this.maxBytes,
    required int Function(T image) sizeOf,
    required void Function(T image) onEvict,
  }) : _sizeOf = sizeOf,
       _onEvict = onEvict;

  final int maxBytes;
  final int Function(T image) _sizeOf;
  final void Function(T image) _onEvict;

  final LinkedHashMap<int, T> _images = LinkedHashMap<int, T>();
  int _heldBytes = 0;

  int get heldBytes => _heldBytes;
  int get length => _images.length;
  Iterable<int> get pages => _images.keys;

  bool contains(int page) => _images.containsKey(page);

  /// The image for [page], without changing its recency.
  T? peek(int page) => _images[page];

  /// Marks [page] as just shown.
  void touch(int page) {
    final image = _images.remove(page);
    if (image != null) _images[page] = image;
  }

  /// Stores [image] for [page] (replacing and evicting an older one) and
  /// trims the cache to [maxBytes].
  ///
  /// Pages for which [keep] answers true (the pages on screen, for a viewer
  /// that renders ahead of time) are not evicted, so the cache can exceed
  /// [maxBytes] while they alone do.
  void put(int page, T image, {bool Function(int page)? keep}) {
    final previous = _images.remove(page);
    if (previous != null) {
      _heldBytes -= _sizeOf(previous);
      if (!identical(previous, image)) _onEvict(previous);
    }
    _images[page] = image;
    _heldBytes += _sizeOf(image);
    if (_heldBytes <= maxBytes) return;
    final victims = <int>[
      for (final candidate in _images.keys)
        if (candidate != page && !(keep?.call(candidate) ?? false)) candidate,
    ];
    for (final victim in victims) {
      if (_heldBytes <= maxBytes) break;
      final evicted = _images.remove(victim) as T;
      _heldBytes -= _sizeOf(evicted);
      _onEvict(evicted);
    }
  }

  /// Evicts every image.
  void clear() {
    final images = List<T>.of(_images.values);
    _images.clear();
    _heldBytes = 0;
    images.forEach(_onEvict);
  }
}

String? _fileNameFromUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  final rawPath = uri?.path.isNotEmpty == true
      ? uri!.path
      : trimmed.split('?').first.split('#').first;
  final segments = rawPath.split('/').where((part) => part.isNotEmpty);
  if (segments.isEmpty) return null;
  return _decodeUriComponent(segments.last).trim();
}

String _baseUrlWithoutTrailingSlash(Uri uri) {
  final withoutFragment = uri.removeFragment();
  final withoutQuery = withoutFragment.replace(query: null);
  return withoutQuery.toString().replaceFirst(RegExp(r'/+$'), '');
}

String _decodeUriComponent(String value) {
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}
