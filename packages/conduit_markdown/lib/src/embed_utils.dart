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

/// Whether [raw] is an MCP App a tool call showed (Open WebUI 0.13):
/// `{type: 'mcp_app', server_id, tool_name, binding, arguments, result}`.
/// It names an app to run rather than content to load, so it has no source.
bool isMcpAppEmbed(Object? raw) => raw is Map && raw['type'] == 'mcp_app';

List<Map<String, dynamic>> normalizeEmbedList(dynamic raw) {
  if (raw is! List) {
    return const <Map<String, dynamic>>[];
  }

  final embeds = <Map<String, dynamic>>[];
  for (final entry in raw) {
    if (isMcpAppEmbed(entry)) {
      embeds.add({
        for (final item in (entry as Map).entries)
          item.key.toString(): item.value,
      });
      continue;
    }
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

/// The embeds as Open WebUI stores them: each source as a string, and an
/// MCP App as the object it was shown with, which its RPC needs.
List<Object>? sanitizeEmbedsForWebUi(List<Map<String, dynamic>>? embeds) {
  if (embeds == null || embeds.isEmpty) {
    return null;
  }

  final normalized = <Object>[
    for (final embed in embeds)
      if (isMcpAppEmbed(embed))
        embed
      else if (extractEmbedSource(embed) case final String source
          when source.isNotEmpty)
        source,
  ];

  return normalized.isEmpty ? null : normalized;
}
