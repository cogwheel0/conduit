import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Utilities for converting OpenWebUI conversation payloads into JSON maps
/// that match the app's `Conversation` / `ChatMessage` schemas. All helpers
/// here are isolate-safe (they only work with primitive JSON types) so they
/// can be executed inside a background worker.

const _uuid = Uuid();

Map<String, dynamic> parseConversationSummary(Map<String, dynamic> chatData) {
  final id = (chatData['id'] ?? '').toString();
  final title = _stringOr(chatData['title'], 'Chat');

  final updatedAtRaw = chatData['updated_at'] ?? chatData['updatedAt'];
  final createdAtRaw = chatData['created_at'] ?? chatData['createdAt'];

  final pinned = chatData['pinned'] as bool? ?? false;
  final archived = chatData['archived'] as bool? ?? false;
  final shareId = chatData['share_id']?.toString();
  final folderId = chatData['folder_id']?.toString();

  String? systemPrompt;
  final chatObject = chatData['chat'];
  if (chatObject is Map<String, dynamic>) {
    final value = chatObject['system'];
    if (value is String && value.trim().isNotEmpty) {
      systemPrompt = value;
    }
  } else if (chatData['system'] is String) {
    final value = (chatData['system'] as String).trim();
    if (value.isNotEmpty) systemPrompt = value;
  }

  return <String, dynamic>{
    'id': id,
    'title': title,
    'createdAt': _parseTimestamp(createdAtRaw).toIso8601String(),
    'updatedAt': _parseTimestamp(updatedAtRaw).toIso8601String(),
    'model': chatData['model']?.toString(),
    'systemPrompt': systemPrompt,
    'messages': const <Map<String, dynamic>>[],
    'metadata': _coerceJsonMap(chatData['metadata']),
    'pinned': pinned,
    'archived': archived,
    'shareId': shareId,
    'folderId': folderId,
    'tags': _coerceStringList(chatData['tags']),
  };
}

Map<String, dynamic> parseFullConversation(Map<String, dynamic> chatData) {
  final id = (chatData['id'] ?? '').toString();
  final title = _stringOr(chatData['title'], 'Chat');

  final updatedAt = _parseTimestamp(
    chatData['updated_at'] ?? chatData['updatedAt'],
  );
  final createdAt = _parseTimestamp(
    chatData['created_at'] ?? chatData['createdAt'],
  );
  final pinned = chatData['pinned'] as bool? ?? false;
  final archived = chatData['archived'] as bool? ?? false;
  final shareId = chatData['share_id']?.toString();
  final folderId = chatData['folder_id']?.toString();

  String? systemPrompt;
  final chatObject = chatData['chat'];
  if (chatObject is Map<String, dynamic>) {
    final value = chatObject['system'];
    if (value is String && value.trim().isNotEmpty) {
      systemPrompt = value;
    }
  } else if (chatData['system'] is String) {
    final value = (chatData['system'] as String).trim();
    if (value.isNotEmpty) systemPrompt = value;
  }

  String? model;
  Map<String, dynamic>? historyMessagesMap;
  List<Map<String, dynamic>>? messagesList;

  if (chatObject is Map<String, dynamic>) {
    final history = chatObject['history'];
    if (history is Map<String, dynamic>) {
      if (history['messages'] is Map<String, dynamic>) {
        historyMessagesMap = history['messages'] as Map<String, dynamic>;
        messagesList = _buildMessagesListFromHistory(history);
      }
    }

    if ((messagesList == null || messagesList.isEmpty) &&
        chatObject['messages'] is List) {
      messagesList = (chatObject['messages'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }

    final models = chatObject['models'];
    if (models is List && models.isNotEmpty) {
      model = models.first?.toString();
    }
  }

  if ((messagesList == null || messagesList.isEmpty) &&
      chatData['messages'] is List) {
    messagesList = (chatData['messages'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  final messages = <Map<String, dynamic>>[];
  if (messagesList != null) {
    var index = 0;
    while (index < messagesList.length) {
      final msgData = Map<String, dynamic>.from(messagesList[index]);
      final historyMsg = historyMessagesMap != null
          ? (historyMessagesMap[msgData['id']] as Map<String, dynamic>?)
          : null;

      final toolCalls = _extractToolCalls(msgData, historyMsg);
      if ((msgData['role']?.toString() ?? '') == 'assistant' &&
          toolCalls != null) {
        final results = <Map<String, dynamic>>[];
        var j = index + 1;
        while (j < messagesList.length) {
          final nextRaw = messagesList[j];
          if ((nextRaw['role']?.toString() ?? '') != 'tool') break;
          results.add({
            'tool_call_id': nextRaw['tool_call_id']?.toString(),
            'content': nextRaw['content'],
            if (nextRaw.containsKey('files')) 'files': nextRaw['files'],
          });
          j++;
        }

        final synthesized = _synthesizeToolDetailsFromToolCallsWithResults(
          toolCalls,
          results,
        );
        final merged = Map<String, dynamic>.from(msgData);
        if (synthesized.isNotEmpty) {
          merged['content'] = synthesized;
        }

        messages.add(
          _parseOpenWebUIMessageToJson(merged, historyMsg: historyMsg),
        );
        index = j;
        continue;
      }

      messages.add(
        _parseOpenWebUIMessageToJson(msgData, historyMsg: historyMsg),
      );
      index++;
    }
  }

  return <String, dynamic>{
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'model': model,
    'systemPrompt': systemPrompt,
    'messages': messages,
    'metadata': _coerceJsonMap(chatData['metadata']),
    'pinned': pinned,
    'archived': archived,
    'shareId': shareId,
    'folderId': folderId,
    'tags': _coerceStringList(chatData['tags']),
  };
}

List<Map<String, dynamic>>? _extractToolCalls(
  Map<String, dynamic> msgData,
  Map<String, dynamic>? historyMsg,
) {
  final toolCallsRaw =
      msgData['tool_calls'] ??
      historyMsg?['tool_calls'] ??
      historyMsg?['toolCalls'];
  if (toolCallsRaw is List) {
    return toolCallsRaw.whereType<Map>().map(_coerceJsonMap).toList();
  }
  return null;
}

Map<String, dynamic> _parseOpenWebUIMessageToJson(
  Map<String, dynamic> msgData, {
  Map<String, dynamic>? historyMsg,
}) {
  dynamic content = msgData['content'];
  if ((content == null || (content is String && content.isEmpty)) &&
      historyMsg != null &&
      historyMsg['content'] != null) {
    content = historyMsg['content'];
  }

  var contentString = '';
  if (content is List) {
    final buffer = StringBuffer();
    for (final entry in content) {
      if (entry is Map && entry['type'] == 'text') {
        final text = entry['text']?.toString();
        if (text != null && text.isNotEmpty) {
          buffer.write(text);
        }
      }
    }
    contentString = buffer.toString();
    if (contentString.trim().isEmpty) {
      final synthesized = _synthesizeToolDetailsFromContentArray(content);
      if (synthesized.isNotEmpty) {
        contentString = synthesized;
      }
    }
  } else {
    contentString = content?.toString() ?? '';
  }

  if (historyMsg != null) {
    final histContent = historyMsg['content'];
    if (histContent is String && histContent.length > contentString.length) {
      contentString = histContent;
    } else if (histContent is List) {
      final buf = StringBuffer();
      for (final entry in histContent) {
        if (entry is Map && entry['type'] == 'text') {
          final text = entry['text']?.toString();
          if (text != null && text.isNotEmpty) {
            buf.write(text);
          }
        }
      }
      final combined = buf.toString();
      if (combined.length > contentString.length) {
        contentString = combined;
      }
    }
  }

  final toolCallsList = _extractToolCalls(msgData, historyMsg);
  if (contentString.trim().isEmpty && toolCallsList != null) {
    final synthesized = _synthesizeToolDetailsFromToolCalls(toolCallsList);
    if (synthesized.isNotEmpty) {
      contentString = synthesized;
    }
  }

  final role = _resolveRole(msgData);

  final effectiveFiles = msgData['files'] ?? historyMsg?['files'];
  List<String>? attachmentIds;
  List<Map<String, dynamic>>? files;
  if (effectiveFiles is List) {
    final attachments = <String>[];
    final allFiles = <Map<String, dynamic>>[];
    for (final entry in effectiveFiles) {
      if (entry is! Map) continue;
      if (entry['file_id'] != null) {
        attachments.add(entry['file_id'].toString());
      } else if (entry['type'] != null && entry['url'] != null) {
        final fileMap = <String, dynamic>{
          'type': entry['type'],
          'url': entry['url'],
        };
        if (entry['name'] != null) fileMap['name'] = entry['name'];
        if (entry['size'] != null) fileMap['size'] = entry['size'];
        allFiles.add(fileMap);

        final url = entry['url'].toString();
        final match = RegExp(r'/api/v1/files/([^/]+)/content').firstMatch(url);
        if (match != null) {
          attachments.add(match.group(1)!);
        }
      }
    }
    attachmentIds = attachments.isNotEmpty ? attachments : null;
    files = allFiles.isNotEmpty ? allFiles : null;
  }

  final statusHistoryRaw =
      historyMsg != null && historyMsg.containsKey('statusHistory')
      ? historyMsg['statusHistory']
      : msgData['statusHistory'];
  final followUpsRaw = historyMsg != null && historyMsg.containsKey('followUps')
      ? historyMsg['followUps']
      : msgData['followUps'] ?? msgData['follow_ups'];
  final codeExecRaw = historyMsg != null
      ? historyMsg['code_executions'] ?? historyMsg['codeExecutions']
      : msgData['code_executions'] ?? msgData['codeExecutions'];
  final sourcesRaw = historyMsg != null && historyMsg.containsKey('sources')
      ? historyMsg['sources']
      : msgData['sources'];

  return <String, dynamic>{
    'id': (msgData['id'] ?? _uuid.v4()).toString(),
    'role': role,
    'content': contentString,
    'timestamp': _parseTimestamp(msgData['timestamp']).toIso8601String(),
    'model': msgData['model']?.toString(),
    'isStreaming': msgData['isStreaming'] as bool? ?? false,
    if (attachmentIds != null) 'attachmentIds': attachmentIds,
    if (files != null) 'files': files,
    'metadata': _coerceJsonMap(msgData['metadata']),
    'statusHistory': _parseStatusHistoryField(statusHistoryRaw),
    'followUps': _coerceStringList(followUpsRaw),
    'codeExecutions': _parseCodeExecutionsField(codeExecRaw),
    'sources': _parseSourcesField(sourcesRaw),
    'usage': _coerceJsonMap(msgData['usage']),
    'versions': const <Map<String, dynamic>>[],
  };
}

String _resolveRole(Map<String, dynamic> msgData) {
  if (msgData['role'] != null) {
    return msgData['role'].toString();
  }
  if (msgData['model'] != null) {
    return 'assistant';
  }
  return 'user';
}

List<Map<String, dynamic>> _buildMessagesListFromHistory(
  Map<String, dynamic> history,
) {
  final messagesMap = history['messages'];
  final currentId = history['currentId']?.toString();
  if (messagesMap is! Map<String, dynamic> || currentId == null) {
    return const [];
  }

  List<Map<String, dynamic>> buildChain(String? id) {
    if (id == null) return const [];
    final raw = messagesMap[id];
    if (raw is! Map) return const [];
    final msg = _coerceJsonMap(raw);
    msg['id'] = id;
    final parentId = msg['parentId']?.toString();
    if (parentId != null && parentId.isNotEmpty) {
      return [...buildChain(parentId), msg];
    }
    return [msg];
  }

  return buildChain(currentId);
}

DateTime _parseTimestamp(dynamic timestamp) {
  if (timestamp == null) return DateTime.now();
  if (timestamp is int) {
    final ts = timestamp > 1000000000000 ? timestamp : timestamp * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ts);
  }
  if (timestamp is String) {
    final parsedInt = int.tryParse(timestamp);
    if (parsedInt != null) {
      final ts = parsedInt > 1000000000000 ? parsedInt : parsedInt * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ts);
    }
    return DateTime.tryParse(timestamp) ?? DateTime.now();
  }
  if (timestamp is double) {
    final ts = timestamp > 1000000000000
        ? timestamp.round()
        : (timestamp * 1000).round();
    return DateTime.fromMillisecondsSinceEpoch(ts);
  }
  return DateTime.now();
}

List<Map<String, dynamic>> _parseStatusHistoryField(dynamic raw) {
  if (raw is List) {
    return raw
        .whereType<Map>()
        .map((entry) => _coerceJsonMap(entry))
        .toList(growable: false);
  }
  return const <Map<String, dynamic>>[];
}

List<String> _coerceStringList(dynamic raw) {
  if (raw is List) {
    return raw
        .whereType<dynamic>()
        .map((value) => value?.toString().trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return [raw.trim()];
  }
  return const <String>[];
}

List<Map<String, dynamic>> _parseCodeExecutionsField(dynamic raw) {
  if (raw is List) {
    return raw
        .whereType<Map>()
        .map((entry) => _coerceJsonMap(entry))
        .toList(growable: false);
  }
  return const <Map<String, dynamic>>[];
}

List<Map<String, dynamic>> _parseSourcesField(dynamic raw) {
  if (raw is List) {
    return raw.whereType<Map>().map(_coerceJsonMap).toList(growable: false);
  }
  if (raw is Map) {
    return [_coerceJsonMap(raw)];
  }
  if (raw is String) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map>().map(_coerceJsonMap).toList();
      }
    } catch (_) {}
  }
  return const <Map<String, dynamic>>[];
}

Map<String, dynamic> _coerceJsonMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value.map((key, v) => MapEntry(key.toString(), _coerceJsonValue(v)));
  }
  if (value is Map) {
    final result = <String, dynamic>{};
    value.forEach((key, v) {
      result[key.toString()] = _coerceJsonValue(v);
    });
    return result;
  }
  return <String, dynamic>{};
}

dynamic _coerceJsonValue(dynamic value) {
  if (value is Map) {
    return _coerceJsonMap(value);
  }
  if (value is List) {
    return value.map(_coerceJsonValue).toList();
  }
  return value;
}

String _stringOr(dynamic value, String fallback) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return fallback;
}

String _synthesizeToolDetailsFromToolCalls(List<Map> calls) {
  final buffer = StringBuffer();
  for (final rawCall in calls) {
    final call = Map<String, dynamic>.from(rawCall);
    final function = call['function'];
    final name =
        (function is Map ? function['name'] : call['name'])?.toString() ??
        'tool';
    final id =
        (call['id']?.toString() ??
        'call_${DateTime.now().millisecondsSinceEpoch}');
    final done = call['done']?.toString() ?? 'true';
    final argsRaw = function is Map ? function['arguments'] : call['arguments'];
    final resRaw =
        call['result'] ??
        call['output'] ??
        (function is Map ? function['result'] : null);
    final attrs = StringBuffer()
      ..write('type="tool_calls"')
      ..write(' done="${_escapeHtmlAttr(done)}"')
      ..write(' id="${_escapeHtmlAttr(id)}"')
      ..write(' name="${_escapeHtmlAttr(name)}"')
      ..write(' arguments="${_escapeHtmlAttr(_jsonStringify(argsRaw))}"');
    final resultStr = _jsonStringify(resRaw);
    if (resultStr.isNotEmpty) {
      attrs.write(' result="${_escapeHtmlAttr(resultStr)}"');
    }
    buffer.writeln(
      '<details ${attrs.toString()}><summary>Tool Executed</summary></details>',
    );
  }
  return buffer.toString().trim();
}

String _synthesizeToolDetailsFromToolCallsWithResults(
  List<Map> calls,
  List<Map> results,
) {
  final buffer = StringBuffer();
  final resultsMap = <String, Map<String, dynamic>>{};
  for (final rawResult in results) {
    final result = Map<String, dynamic>.from(rawResult);
    final id = result['tool_call_id']?.toString();
    if (id != null) {
      resultsMap[id] = result;
    }
  }

  for (final rawCall in calls) {
    final call = Map<String, dynamic>.from(rawCall);
    final function = call['function'];
    final name =
        (function is Map ? function['name'] : call['name'])?.toString() ??
        'tool';
    final id =
        (call['id']?.toString() ??
        'call_${DateTime.now().millisecondsSinceEpoch}');
    final argsRaw = function is Map ? function['arguments'] : call['arguments'];
    final resultEntry = resultsMap[id];
    final resRaw = resultEntry != null ? resultEntry['content'] : null;
    final filesRaw = resultEntry != null ? resultEntry['files'] : null;

    final attrs = StringBuffer()
      ..write('type="tool_calls"')
      ..write(
        ' done="${_escapeHtmlAttr(resultEntry != null ? 'true' : 'false')}"',
      )
      ..write(' id="${_escapeHtmlAttr(id)}"')
      ..write(' name="${_escapeHtmlAttr(name)}"')
      ..write(' arguments="${_escapeHtmlAttr(_jsonStringify(argsRaw))}"');
    final resultStr = _jsonStringify(resRaw);
    if (resultStr.isNotEmpty) {
      attrs.write(' result="${_escapeHtmlAttr(resultStr)}"');
    }
    final filesStr = _jsonStringify(filesRaw);
    if (filesStr.isNotEmpty) {
      attrs.write(' files="${_escapeHtmlAttr(filesStr)}"');
    }
    buffer.writeln(
      '<details ${attrs.toString()}><summary>${resultEntry != null ? 'Tool Executed' : 'Executing...'}</summary></details>',
    );
  }

  return buffer.toString().trim();
}

String _synthesizeToolDetailsFromContentArray(List<dynamic> content) {
  final buffer = StringBuffer();
  for (final item in content) {
    if (item is! Map) continue;
    final type = item['type']?.toString();
    if (type == null) continue;
    if (type == 'tool_calls') {
      final calls = <Map<String, dynamic>>[];
      if (item['content'] is List) {
        for (final entry in item['content'] as List) {
          if (entry is Map) {
            calls.add(Map<String, dynamic>.from(entry));
          }
        }
      }

      final results = <Map<String, dynamic>>[];
      if (item['results'] is List) {
        for (final entry in item['results'] as List) {
          if (entry is Map) {
            results.add(Map<String, dynamic>.from(entry));
          }
        }
      }
      final synthesized = _synthesizeToolDetailsFromToolCallsWithResults(
        calls,
        results,
      );
      if (synthesized.isNotEmpty) {
        buffer.writeln(synthesized);
      }
      continue;
    }

    if (type == 'tool_call' || type == 'function_call') {
      final name = (item['name'] ?? item['tool'] ?? 'tool').toString();
      final id =
          (item['id']?.toString() ??
          'call_${DateTime.now().millisecondsSinceEpoch}');
      final argsStr = _jsonStringify(item['arguments'] ?? item['args']);
      final resStr = item['result'] ?? item['output'] ?? item['response'];
      final attrs = StringBuffer()
        ..write('type="tool_calls"')
        ..write(' done="${_escapeHtmlAttr(resStr != null ? 'true' : 'false')}"')
        ..write(' id="${_escapeHtmlAttr(id)}"')
        ..write(' name="${_escapeHtmlAttr(name)}"')
        ..write(' arguments="${_escapeHtmlAttr(argsStr)}"');
      final result = _jsonStringify(resStr);
      if (result.isNotEmpty) {
        attrs.write(' result="${_escapeHtmlAttr(result)}"');
      }
      buffer.writeln(
        '<details ${attrs.toString()}><summary>${resStr != null ? 'Tool Executed' : 'Executing...'}</summary></details>',
      );
    }
  }
  return buffer.toString().trim();
}

String _jsonStringify(dynamic value) {
  if (value == null) return '';
  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}

String _escapeHtmlAttr(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

List<Map<String, dynamic>> parseConversationSummariesWorker(
  Map<String, dynamic> payload,
) {
  final pinnedRaw = payload['pinned'];
  final archivedRaw = payload['archived'];
  final regularRaw = payload['regular'];

  final pinned = <Map<String, dynamic>>[];
  if (pinnedRaw is List) {
    for (final entry in pinnedRaw) {
      if (entry is Map) {
        pinned.add(Map<String, dynamic>.from(entry));
      }
    }
  }

  final archived = <Map<String, dynamic>>[];
  if (archivedRaw is List) {
    for (final entry in archivedRaw) {
      if (entry is Map) {
        archived.add(Map<String, dynamic>.from(entry));
      }
    }
  }

  final regular = <Map<String, dynamic>>[];
  if (regularRaw is List) {
    for (final entry in regularRaw) {
      if (entry is Map) {
        regular.add(Map<String, dynamic>.from(entry));
      }
    }
  }

  final summaries = <Map<String, dynamic>>[];
  final pinnedIds = <String>{};
  final archivedIds = <String>{};

  for (final entry in pinned) {
    final summary = parseConversationSummary(entry);
    summary['pinned'] = true;
    summaries.add(summary);
    pinnedIds.add(summary['id'] as String);
  }

  for (final entry in archived) {
    final summary = parseConversationSummary(entry);
    summary['archived'] = true;
    summaries.add(summary);
    archivedIds.add(summary['id'] as String);
  }

  for (final entry in regular) {
    final summary = parseConversationSummary(entry);
    final id = summary['id'] as String;
    if (pinnedIds.contains(id) || archivedIds.contains(id)) {
      continue;
    }
    summaries.add(summary);
  }

  return summaries;
}

Map<String, dynamic> parseFullConversationWorker(Map<String, dynamic> payload) {
  final raw = payload['conversation'];
  if (raw is Map<String, dynamic>) {
    return parseFullConversation(raw);
  }
  if (raw is Map) {
    return parseFullConversation(Map<String, dynamic>.from(raw));
  }
  return parseFullConversation(<String, dynamic>{});
}
