import '../models/chat_message.dart';

/// Parses OpenWebUI style source payloads into flattened chat source references.
List<ChatSourceReference> parseOpenWebUISourceList(dynamic raw) {
  if (raw is! List) {
    return const <ChatSourceReference>[];
  }

  final aggregated = <String, _CitationAccumulator>{};
  var fallbackIndex = 0;

  for (final entry in raw) {
    if (entry is! Map) {
      continue;
    }

    final entryMap = _asStringKeyMap(entry);
    if (entryMap == null) {
      continue;
    }

    final baseSource =
        _asStringKeyMap(entryMap['source']) ?? <String, dynamic>{};
    entryMap.remove('source');

    for (final key in ['id', 'name', 'title', 'url', 'link', 'type']) {
      final value = entryMap[key];
      if (value != null && baseSource[key] == null) {
        baseSource[key] = value;
      }
    }

    final documents = entryMap['document'] is List
        ? (entryMap['document'] as List)
        : const [];
    final metadataRaw = entryMap['metadata'];
    final metadataList = metadataRaw is List
        ? metadataRaw
        : metadataRaw is Map
        ? [metadataRaw]
        : const [];
    final distances = entryMap['distances'] is List
        ? (entryMap['distances'] as List)
        : const [];

    final counts = <int>[
      documents.length,
      metadataList.length,
      distances.length,
    ].where((len) => len > 0).toList();
    final loopCount = counts.isEmpty
        ? 1
        : counts.reduce((value, element) => value > element ? value : element);

    for (var index = 0; index < loopCount; index++) {
      final document = index < documents.length ? documents[index] : null;
      final metadata = index < metadataList.length ? metadataList[index] : null;
      final distance = index < distances.length ? distances[index] : null;

      final metadataMap = _asStringKeyMap(metadata) ?? <String, dynamic>{};

      final idCandidate = _firstNonEmpty([
        metadataMap['source'],
        metadataMap['id'],
        baseSource['id'],
        entryMap['id'],
      ]);

      final key = idCandidate?.isNotEmpty == true
          ? idCandidate!
          : '__fallback_${fallbackIndex++}';

      final accumulator = aggregated.putIfAbsent(
        key,
        () => _CitationAccumulator(
          key: key,
          source: Map<String, dynamic>.from(baseSource),
        ),
      );
      final isFirstOccurrence = !accumulator.hasMergedData;

      accumulator.explicitId ??= idCandidate?.toString();
      accumulator.explicitType ??= _firstNonEmpty([
        baseSource['type'],
        entryMap['type'],
        metadataMap['type'],
      ])?.toString();

      final metadataName = _firstNonEmpty([
        metadataMap['name'],
        metadataMap['title'],
      ])?.toString();
      if (metadataName != null && metadataName.isNotEmpty) {
        if (isFirstOccurrence) {
          accumulator.source['name'] = metadataName;
        } else {
          accumulator.source['name'] ??= metadataName;
        }
        accumulator.source['title'] ??= metadataName;
      }

      if (_looksLikeUrl(idCandidate)) {
        accumulator.source['url'] ??= idCandidate;
        accumulator.source['name'] ??= idCandidate;
      }

      final preferredUrl = _firstUrl([
        accumulator.source['url'],
        baseSource['url'],
        metadataMap['url'],
        metadataMap['link'],
        _looksLikeUrl(idCandidate) ? idCandidate : null,
      ]);
      if (preferredUrl != null) {
        if (isFirstOccurrence || accumulator.source['url'] == null) {
          accumulator.source['url'] = preferredUrl;
        }
      } else {
        final fallbackUrl = _firstUrl([metadataMap['source']]);
        if (fallbackUrl != null) {
          accumulator.source['url'] ??= fallbackUrl;
        }
      }

      final snippet = _extractSnippet(document);
      if (snippet != null && snippet.isNotEmpty) {
        accumulator.documents.add(snippet);
      }

      if (metadataMap.isNotEmpty) {
        accumulator.metadata.add(metadataMap);
      }

      if (distance != null) {
        accumulator.distances.add(distance);
      }

      accumulator.hasMergedData = true;
    }
  }

  final results = <ChatSourceReference>[];

  for (final accumulator in aggregated.values) {
    final id = accumulator.explicitId;
    final title = _firstNonEmpty([
      accumulator.source['name'],
      accumulator.source['title'],
      id,
    ])?.toString();

    final urlCandidate = _firstNonEmpty([
      accumulator.source['url'],
      id,
    ])?.toString();
    final url = _looksLikeUrl(urlCandidate) ? urlCandidate : null;

    final snippet = accumulator.documents.firstWhere(
      (doc) => doc.trim().isNotEmpty,
      orElse: () => '',
    );

    final metadata = <String, dynamic>{
      if (accumulator.metadata.isNotEmpty) 'items': accumulator.metadata,
      if (accumulator.documents.isNotEmpty) 'documents': accumulator.documents,
      if (accumulator.distances.isNotEmpty) 'distances': accumulator.distances,
      if (accumulator.source.isNotEmpty) 'source': accumulator.source,
    };

    metadata.removeWhere((key, value) {
      if (value == null) return true;
      if (value is List && value.isEmpty) return true;
      if (value is Map && value.isEmpty) return true;
      return false;
    });

    results.add(
      ChatSourceReference(
        id: (id != null && id.startsWith('__fallback_')) ? null : id,
        title: title,
        url: url,
        snippet: snippet.isNotEmpty ? snippet : null,
        type: accumulator.explicitType,
        metadata: metadata.isNotEmpty ? metadata : null,
      ),
    );
  }

  return results;
}

Map<String, dynamic>? _asStringKeyMap(dynamic value) {
  if (value is Map) {
    final map = <String, dynamic>{};
    value.forEach((key, entryValue) {
      map[key.toString()] = entryValue;
    });
    return map;
  }
  return null;
}

String? _firstNonEmpty(Iterable<dynamic> values) {
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

bool _looksLikeUrl(String? value) {
  if (value == null) {
    return false;
  }
  return value.startsWith('http://') || value.startsWith('https://');
}

String? _firstUrl(Iterable<dynamic> values) {
  for (final value in values) {
    final url = value?.toString();
    if (_looksLikeUrl(url)) {
      return url;
    }
  }
  return null;
}

String? _extractSnippet(dynamic document) {
  if (document == null) {
    return null;
  }
  if (document is String) {
    return document.trim();
  }
  return document.toString().trim().isNotEmpty ? document.toString() : null;
}

class _CitationAccumulator {
  _CitationAccumulator({required this.key, required this.source});

  final String key;
  final Map<String, dynamic> source;
  final List<String> documents = [];
  final List<Map<String, dynamic>> metadata = [];
  final List<dynamic> distances = [];
  String? explicitId;
  String? explicitType;
  bool hasMergedData = false;
}
