import '../../../core/models/chat_message.dart';

/// Shared helpers for deriving display labels and URLs from source references.
///
/// Flutter stores OpenWebUI citations in a flattened
/// [ChatSourceReference] model. These helpers preserve the web renderer's
/// display priorities:
/// 1. Prefer a human-readable metadata name/title when present.
/// 2. Fall back to a URL-like identifier only when no better label exists.
/// 3. Render URL-like labels as bare domains for compact inline chips.
class SourceReferenceHelper {
  const SourceReferenceHelper._();

  /// Returns the label that should back UI display for this source.
  ///
  /// This keeps the web app's preference order, where `metadata.name`
  /// outranks the raw URL.
  static String getSourceLabel(ChatSourceReference source, int index) {
    final metadata = primaryMetadata(source);
    final nestedSource = nestedSourceMetadata(source);

    return _firstNonEmpty([
          metadata?['name'],
          metadata?['title'],
          source.title,
          nestedSource?['name'],
          nestedSource?['title'],
          source.id,
          source.url,
        ]) ??
        'Source ${index + 1}';
  }

  /// Returns the compact label used by inline citation chips.
  ///
  /// OpenWebUI prefers a stripped URL/domain for inline source chips whenever
  /// a canonical URL is available, even if the expanded source list uses a
  /// richer title.
  static String getInlineSourceLabel(ChatSourceReference source, int index) {
    final title = source.title;
    final url = getSourceUrl(source);
    if (title != null &&
        !looksLikeUrl(title) &&
        url == source.url &&
        _looksLikeDomain(title)) {
      return source.title!;
    }

    if (url != null) {
      return extractDomain(url);
    }

    return getSourceLabel(source, index);
  }

  /// Returns the best launchable URL for a source, if any.
  ///
  /// Canonical URLs are preferred over metadata fallback fields like
  /// `metadata.source`, which can contain redirect or internal search URLs.
  static String? getSourceUrl(ChatSourceReference source) {
    final metadata = primaryMetadata(source);
    final nestedSource = nestedSourceMetadata(source);

    final candidate = _firstNonEmpty([
      source.url,
      nestedSource?['url'],
      metadata?['url'],
      metadata?['link'],
      nestedSource?['link'],
      source.id,
      source.title,
      metadata?['source'],
    ]);

    return looksLikeUrl(candidate) ? candidate : null;
  }

  /// Returns the primary metadata entry for a flattened source.
  static Map<String, dynamic>? primaryMetadata(ChatSourceReference source) {
    final metadata = source.metadata;
    if (metadata == null) {
      return null;
    }

    final items = metadata['items'];
    if (items is List) {
      for (final item in items) {
        if (item is Map) {
          return _stringKeyMap(item);
        }
      }
    }

    return null;
  }

  /// Returns the nested `source` metadata map when present.
  static Map<String, dynamic>? nestedSourceMetadata(
    ChatSourceReference source,
  ) {
    final metadata = source.metadata;
    if (metadata == null) {
      return null;
    }
    return _stringKeyMap(metadata['source']);
  }

  /// Converts URL-like labels into compact domains and truncates long labels.
  static String formatDisplayTitle(String title) {
    if (title.isEmpty) {
      return 'N/A';
    }

    final normalized = title.startsWith('http') ? extractDomain(title) : title;

    if (normalized.length > 30) {
      return '${normalized.substring(0, 15)}...'
          '${normalized.substring(normalized.length - 10)}';
    }

    return normalized;
  }

  /// Extracts the domain from a URL for compact display.
  static String extractDomain(String url) {
    try {
      final uri = Uri.parse(url);
      var domain = uri.host;
      if (domain.startsWith('www.')) {
        domain = domain.substring(4);
      }
      return domain;
    } catch (_) {
      return url;
    }
  }

  /// Returns whether a value looks like an HTTP(S) URL.
  static bool looksLikeUrl(String? value) {
    if (value == null) {
      return false;
    }
    return value.startsWith('http://') || value.startsWith('https://');
  }

  static bool _looksLikeDomain(String value) {
    final trimmed = value.trim();
    if (trimmed.contains(' ')) return false;
    return RegExp(r'^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$').hasMatch(trimmed);
  }

  static String? _firstNonEmpty(Iterable<dynamic> values) {
    for (final value in values) {
      if (value == null) {
        continue;
      }

      final stringValue = value.toString();
      if (stringValue.isNotEmpty) {
        return stringValue;
      }
    }

    return null;
  }

  static Map<String, dynamic>? _stringKeyMap(dynamic value) {
    if (value is! Map) {
      return null;
    }

    final map = <String, dynamic>{};
    value.forEach((key, entryValue) {
      map[key.toString()] = entryValue;
    });
    return map;
  }
}
