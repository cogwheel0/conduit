String? extractEmbedSource(Object? raw) {
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  if (raw is Map) {
    for (final key in const ['src', 'url', 'html', 'content']) {
      final value = raw[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
  }

  return null;
}

List<Map<String, dynamic>> normalizeEmbedList(dynamic raw) {
  if (raw is! List) {
    return const <Map<String, dynamic>>[];
  }

  final embeds = <Map<String, dynamic>>[];
  for (final entry in raw) {
    final source = extractEmbedSource(entry);
    if (source == null) {
      continue;
    }

    if (entry is Map) {
      final normalized = <String, dynamic>{};
      entry.forEach((key, value) {
        normalized[key.toString()] = value;
      });
      normalized['src'] = source;
      embeds.add(normalized);
      continue;
    }

    embeds.add({'src': source});
  }

  return embeds;
}

List<String>? sanitizeEmbedsForWebUi(List<Map<String, dynamic>>? embeds) {
  if (embeds == null || embeds.isEmpty) {
    return null;
  }

  final normalized = embeds
      .map(extractEmbedSource)
      .whereType<String>()
      .where((value) => value.isNotEmpty)
      .toList(growable: false);

  return normalized.isEmpty ? null : normalized;
}
