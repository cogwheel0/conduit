import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../models/conversation.dart';
import '../utils/embed_utils.dart';
import '../utils/message_tree_utils.dart' as message_tree;
import '../utils/openwebui_source_parser.dart';
import 'semantic_message_builder.dart';
import 'structured_output.dart';
import 'structured_output_renderer.dart';

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
  final lastReadAt = _parseOptionalTimestamp(
    chatData['last_read_at'] ?? chatData['lastReadAt'],
  );

  final pinned = _safeBool(chatData['pinned']) ?? false;
  final archived = _safeBool(chatData['archived']) ?? false;
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
    'lastReadAt': lastReadAt?.toIso8601String(),
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
  final lastReadAt = _parseOptionalTimestamp(
    chatData['last_read_at'] ?? chatData['lastReadAt'],
  );
  final pinned = _safeBool(chatData['pinned']) ?? false;
  final archived = _safeBool(chatData['archived']) ?? false;
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
            if (nextRaw.containsKey('embeds')) 'embeds': nextRaw['embeds'],
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

        final parsed = _parseOpenWebUIMessageToJson(
          merged,
          historyMsg: historyMsg,
        );
        // Add versions from siblings
        _addVersionsFromSiblings(parsed, msgData, historyMessagesMap);
        messages.add(parsed);
        index = j;
        continue;
      }

      final parsed = _parseOpenWebUIMessageToJson(
        msgData,
        historyMsg: historyMsg,
      );
      // Add versions from siblings
      _addVersionsFromSiblings(parsed, msgData, historyMessagesMap);
      messages.add(parsed);
      index++;
    }
  }

  return <String, dynamic>{
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'lastReadAt': lastReadAt?.toIso8601String(),
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

/// Add versions from sibling messages (alternative responses with same parent).
/// Siblings are stored in `_siblings` by `_buildMessagesListFromHistory`.
void _addVersionsFromSiblings(
  Map<String, dynamic> parsed,
  Map<String, dynamic> msgData,
  Map<String, dynamic>? historyMessagesMap,
) {
  final siblings = msgData['_siblings'];
  if (siblings is! List || siblings.isEmpty) return;

  final versions = <Map<String, dynamic>>[];
  for (final siblingData in siblings) {
    if (siblingData is! Map<String, dynamic>) continue;

    final siblingId = siblingData['id']?.toString();
    final historyMsg = historyMessagesMap != null && siblingId != null
        ? (historyMessagesMap[siblingId] as Map<String, dynamic>?)
        : null;

    // Parse the sibling as a version
    final version = _parseSiblingAsVersion(siblingData, historyMsg: historyMsg);
    if (version != null) {
      versions.add(version);
    }
  }

  if (versions.isNotEmpty) {
    parsed['versions'] = versions;
  }
}

/// Parse a sibling message as a ChatMessageVersion JSON map.
Map<String, dynamic>? _parseSiblingAsVersion(
  Map<String, dynamic> msgData, {
  Map<String, dynamic>? historyMsg,
}) {
  // Extract content (same logic as _parseOpenWebUIMessageToJson)
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
  } else {
    contentString = content?.toString() ?? '';
  }

  if (historyMsg != null) {
    final histContent = historyMsg['content'];
    if (histContent is String && histContent.length > contentString.length) {
      contentString = histContent;
    }
  }

  final outputItems = _effectiveOutputItems(msgData, historyMsg);
  if (outputItems.isNotEmpty) {
    final outputBlocks = parseOpenWebUIStructuredOutput(outputItems);
    final outputContent = _mergeContentWithStructuredOutput(
      contentString,
      outputBlocks,
    );
    if (outputContent.isNotEmpty) {
      contentString = outputContent;
    }
  }

  // Extract files
  final effectiveFiles = msgData['files'] ?? historyMsg?['files'];
  List<Map<String, dynamic>>? files;
  if (effectiveFiles is List) {
    final allFiles = <Map<String, dynamic>>[];
    for (final entry in effectiveFiles) {
      if (entry is! Map) continue;
      if (entry['type'] != null && entry['url'] != null) {
        final fileMap = <String, dynamic>{
          'type': entry['type'],
          'url': entry['url'],
        };
        if (entry['name'] != null) fileMap['name'] = entry['name'];
        if (entry['size'] != null) fileMap['size'] = entry['size'];
        if (entry['content_type'] != null) {
          fileMap['content_type'] = entry['content_type'];
        }
        allFiles.add(fileMap);
      }
    }
    files = allFiles.isNotEmpty ? allFiles : null;
  }

  final embeds = normalizeEmbedList(msgData['embeds'] ?? historyMsg?['embeds']);

  // Extract other fields
  final sourcesRaw = historyMsg != null
      ? historyMsg['sources'] ?? historyMsg['citations']
      : msgData['sources'] ?? msgData['citations'];
  final followUpsRaw = historyMsg != null
      ? historyMsg['followUps'] ?? historyMsg['follow_ups']
      : msgData['followUps'] ?? msgData['follow_ups'];
  final codeExecRaw = historyMsg != null
      ? historyMsg['codeExecutions'] ?? historyMsg['code_executions']
      : msgData['codeExecutions'] ?? msgData['code_executions'];
  final rawUsage = _coerceJsonMap(historyMsg?['usage'] ?? msgData['usage']);
  final errorData = _extractErrorData(msgData, historyMsg);
  final modelName = _extractOpenWebUiModelName(msgData, historyMsg);

  return <String, dynamic>{
    'id': (msgData['id'] ?? _uuid.v4()).toString(),
    'content': contentString,
    'timestamp': _parseTimestamp(msgData['timestamp']).toIso8601String(),
    if ((msgData['model'] ?? historyMsg?['model']) != null)
      'model': (msgData['model'] ?? historyMsg?['model']).toString(),
    'modelName': ?modelName,
    'files': ?files,
    if (embeds.isNotEmpty) 'embeds': embeds,
    'sources': _parseSourcesField(sourcesRaw),
    'followUps': _coerceStringList(followUpsRaw),
    'codeExecutions': _parseCodeExecutionsField(codeExecRaw),
    if (rawUsage.isNotEmpty) 'usage': rawUsage,
    if (outputItems.isNotEmpty) 'output': outputItems,
    'error': ?errorData,
  };
}

/// Extract error data from OpenWebUI message format.
/// OpenWebUI stores errors in a separate 'error' field with 'content' inside.
/// Returns a map suitable for ChatMessageError.fromJson().
Map<String, dynamic>? _extractErrorData(
  Map<String, dynamic> msgData,
  Map<String, dynamic>? historyMsg,
) {
  // Check msgData first, then historyMsg
  final errorRaw = msgData['error'] ?? historyMsg?['error'];
  if (errorRaw == null) return null;

  // Handle different error formats from OpenWebUI
  if (errorRaw is Map) {
    // Most common: { error: { content: "error message" } }
    final content = errorRaw['content'];
    if (content is String && content.isNotEmpty) {
      return {'content': content};
    }
    // Alternative: { error: { message: "error message" } }
    final message = errorRaw['message'];
    if (message is String && message.isNotEmpty) {
      return {'content': message};
    }
    // Nested error: { error: { error: { message: "..." } } }
    final nestedError = errorRaw['error'];
    if (nestedError is Map) {
      final nestedMessage = nestedError['message'];
      if (nestedMessage is String && nestedMessage.isNotEmpty) {
        return {'content': nestedMessage};
      }
    }
    // FastAPI detail format: { detail: "..." }
    final detail = errorRaw['detail'];
    if (detail is String && detail.isNotEmpty) {
      return {'content': detail};
    }
    // If it's a map but we couldn't extract content, still return an error
    // to indicate there was an error (matches legacy error === true behavior)
    return const {'content': null};
  } else if (errorRaw is String && errorRaw.isNotEmpty) {
    // Simple string error
    return {'content': errorRaw};
  } else if (errorRaw == true) {
    // Legacy format: error === true means content IS the error message
    // Return a marker so the UI knows this is an error message
    return const {'content': null};
  }

  return null;
}

Map<String, dynamic>? _extractOpenWebUiMessageMetadata(
  Map<String, dynamic> msgData, {
  Map<String, dynamic>? historyMsg,
  required String role,
}) {
  final metadata = <String, dynamic>{
    ..._coerceJsonMap(msgData['metadata']),
    ..._coerceJsonMap(historyMsg?['metadata']),
  };

  final rawParentId = historyMsg?['parentId'] ?? msgData['parentId'];
  if (rawParentId != null) {
    final parentId = rawParentId.toString().trim();
    if (parentId.isNotEmpty) {
      metadata['parentId'] = parentId;
    }
  }

  final rawChildrenIds = historyMsg?['childrenIds'] ?? msgData['childrenIds'];
  if (rawChildrenIds is List) {
    metadata['childrenIds'] = rawChildrenIds
        .map((child) => child?.toString().trim() ?? '')
        .where((child) => child.isNotEmpty)
        .toList(growable: false);
  }

  final rawModels = historyMsg?['models'] ?? msgData['models'];
  if (role == 'user' && rawModels is List) {
    final models = rawModels
        .map((model) => model?.toString().trim() ?? '')
        .where((model) => model.isNotEmpty)
        .toList(growable: false);
    if (models.isNotEmpty) {
      metadata['models'] = models;
    }
  }

  final modelName = _extractOpenWebUiModelName(msgData, historyMsg);
  if (modelName != null) {
    metadata['modelName'] = modelName;
  }

  return metadata.isEmpty ? null : metadata;
}

String? _extractOpenWebUiModelName(
  Map<String, dynamic> msgData,
  Map<String, dynamic>? historyMsg,
) {
  // Walk candidates in priority order, skipping null AND empty/whitespace
  // values so an empty `modelName` does not shadow a populated `model_name`.
  for (final candidate in [
    historyMsg?['modelName'],
    historyMsg?['model_name'],
    msgData['modelName'],
    msgData['model_name'],
  ]) {
    final value = candidate?.toString().trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
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

  final outputItems = _effectiveOutputItems(msgData, historyMsg);
  if (outputItems.isNotEmpty) {
    final outputBlocks = parseOpenWebUIStructuredOutput(outputItems);
    final outputContent = _mergeContentWithStructuredOutput(
      contentString,
      outputBlocks,
    );
    if (outputContent.isNotEmpty) {
      contentString = outputContent;
    }
  }

  // Extract error field from OpenWebUI - preserve it separately for round-trip
  final errorData = _extractErrorData(msgData, historyMsg);

  final role = _resolveRole(msgData);
  final metadata = _extractOpenWebUiMessageMetadata(
    msgData,
    historyMsg: historyMsg,
    role: role,
  );

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
        if (entry['content_type'] != null) {
          fileMap['content_type'] = entry['content_type'];
        }
        final headers = _coerceStringMap(entry['headers']);
        if (headers != null && headers.isNotEmpty) {
          fileMap['headers'] = headers;
        }
        allFiles.add(fileMap);

        final url = entry['url'].toString();
        // Handle all URL formats:
        // 1. /api/v1/files/{id} and /api/v1/files/{id}/content (old format)
        // 2. Just a file ID like "abc-123-def" (new OpenWebUI format)
        final match = RegExp(
          r'/api/v1/files/([^/]+)(?:/content)?$',
        ).firstMatch(url);
        if (match != null) {
          attachments.add(match.group(1)!);
        } else if (!url.startsWith('data:') &&
            !url.startsWith('http') &&
            !url.startsWith('/')) {
          // New format: URL is just a bare file ID (UUID-like)
          // Validate it looks like a reasonable ID (not an empty string)
          if (url.isNotEmpty) {
            attachments.add(url);
          }
        }
      }
    }
    attachmentIds = attachments.isNotEmpty ? attachments : null;
    files = allFiles.isNotEmpty ? allFiles : null;
  }
  final embeds = normalizeEmbedList(msgData['embeds'] ?? historyMsg?['embeds']);

  final statusHistoryRaw = historyMsg != null
      ? historyMsg['statusHistory'] ?? historyMsg['status_history']
      : msgData['statusHistory'] ?? msgData['status_history'];
  final followUpsRaw = historyMsg != null
      ? historyMsg['followUps'] ?? historyMsg['follow_ups']
      : msgData['followUps'] ?? msgData['follow_ups'];
  final codeExecRaw = historyMsg != null
      ? historyMsg['codeExecutions'] ?? historyMsg['code_executions']
      : msgData['codeExecutions'] ?? msgData['code_executions'];
  final sourcesRaw = historyMsg != null
      ? historyMsg['sources'] ?? historyMsg['citations']
      : msgData['sources'] ?? msgData['citations'];

  // Parse usage data - Open WebUI stores this in 'usage' field on messages
  final rawUsage = _coerceJsonMap(historyMsg?['usage'] ?? msgData['usage']);
  final Map<String, dynamic>? usage = rawUsage.isEmpty ? null : rawUsage;

  return <String, dynamic>{
    'id': (msgData['id'] ?? _uuid.v4()).toString(),
    'role': role,
    'content': contentString,
    'timestamp': _parseTimestamp(msgData['timestamp']).toIso8601String(),
    'model': (msgData['model'] ?? historyMsg?['model'])?.toString(),
    'isStreaming': _safeBool(msgData['isStreaming']) ?? false,
    'attachmentIds': ?attachmentIds,
    'files': ?files,
    if (embeds.isNotEmpty) 'embeds': embeds,
    'metadata': metadata ?? const <String, dynamic>{},
    'statusHistory': _parseStatusHistoryField(statusHistoryRaw),
    'followUps': _coerceStringList(followUpsRaw),
    'codeExecutions': _parseCodeExecutionsField(codeExecRaw),
    'sources': _parseSourcesField(sourcesRaw),
    'usage': usage,
    'versions': const <Map<String, dynamic>>[],
    if (outputItems.isNotEmpty) 'output': outputItems,
    'error': ?errorData,
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

/// Build the message chain from history, following parent links from currentId.
/// Also collects sibling messages (alternative versions) for each message.
List<Map<String, dynamic>> _buildMessagesListFromHistory(
  Map<String, dynamic> history,
) {
  final rawMessagesMap = history['messages'];
  final currentId = history['currentId']?.toString();
  if (rawMessagesMap is! Map || currentId == null) {
    return const [];
  }

  final messagesMap = <String, Map<String, dynamic>>{};
  rawMessagesMap.forEach((key, value) {
    final id = message_tree.normalizeMessageId(key);
    if (id == null || value is! Map) {
      return;
    }
    messagesMap[id] = _coerceJsonMap(value)..['id'] = id;
  });

  final chain = message_tree.chainToRoot<Map<String, dynamic>>(
    currentId,
    messagesById: messagesMap,
    parentIdOf: message_tree.rawMessageParentId,
  );

  // For each message in the chain, find sibling versions
  // Siblings are other children of the same parent
  for (final msg in chain) {
    final msgId = message_tree.normalizeMessageId(msg['id']);
    if (msgId == null) continue;

    final siblings = message_tree.sameRoleSiblings<Map<String, dynamic>>(
      messageId: msgId,
      message: msg,
      messagesById: messagesMap,
      parentIdOf: message_tree.rawMessageParentId,
      childrenIdsOf: message_tree.rawMessageChildrenIds,
      roleOf: message_tree.rawMessageRole,
    );
    if (siblings.isNotEmpty) {
      msg['_siblings'] = siblings;
    }
  }

  return chain;
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

DateTime? _parseOptionalTimestamp(dynamic timestamp) {
  if (timestamp == null) return null;
  if (timestamp is String && timestamp.trim().isEmpty) return null;
  return _parseTimestamp(timestamp);
}

List<Map<String, dynamic>> _parseStatusHistoryField(dynamic raw) {
  if (raw is List) {
    final results = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      try {
        results.add(_coerceJsonMap(entry));
      } catch (_) {
        // Skip malformed status entries to prevent error boundary
      }
    }
    return results;
  }
  return const <Map<String, dynamic>>[];
}

Map<String, String>? _coerceStringMap(dynamic raw) {
  if (raw is Map) {
    final result = <String, String>{};
    raw.forEach((key, value) {
      final keyString = key?.toString();
      final valueString = value?.toString();
      if (keyString != null &&
          keyString.isNotEmpty &&
          valueString != null &&
          valueString.isNotEmpty) {
        result[keyString] = valueString;
      }
    });
    return result.isEmpty ? null : result;
  }
  return null;
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
  final normalized = _coerceSourcesList(raw);
  if (normalized == null || normalized.isEmpty) {
    return const <Map<String, dynamic>>[];
  }

  final parsed = parseOpenWebUISourceList(normalized);
  if (parsed.isNotEmpty) {
    return parsed
        .map((reference) => reference.toJson())
        .toList(growable: false);
  }

  return normalized
      .whereType<Map>()
      .map(_coerceJsonMap)
      .toList(growable: false);
}

List<dynamic>? _coerceSourcesList(dynamic raw) {
  if (raw is List) {
    return raw;
  }
  if (raw is Iterable) {
    return raw.toList(growable: false);
  }
  if (raw is Map) {
    return [raw];
  }
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded;
      }
      if (decoded is Map) {
        return [decoded];
      }
    } catch (_) {}
  }
  return null;
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

List<Map<String, dynamic>> _normalizeOutputItems(dynamic raw) {
  if (raw is! List) return const [];
  final items = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is Map) {
      items.add(_coerceJsonMap(item));
    }
  }
  return List<Map<String, dynamic>>.unmodifiable(items);
}

List<Map<String, dynamic>> _effectiveOutputItems(
  Map<String, dynamic> msgData,
  Map<String, dynamic>? historyMsg,
) {
  final directItems = _normalizeOutputItems(msgData['output']);
  if (directItems.isNotEmpty || historyMsg == null) {
    return directItems;
  }
  return _normalizeOutputItems(historyMsg['output']);
}

String _mergeContentWithStructuredOutput(
  String content,
  List<StructuredOutputBlock> outputBlocks,
) {
  final hasDetails = structuredOutputBlocksContainDetails(outputBlocks);
  final baseContent = _stripRenderedSemanticDetails(content);
  final strippedSemanticDetails = baseContent != content;
  final outputPlainText = structuredOutputBlocksPlainText(outputBlocks);
  final hasOutputPlainText = outputPlainText.trim().isNotEmpty;
  final outputTextIsAuthoritative =
      hasOutputPlainText && outputPlainText.length > baseContent.length;
  final effectiveContent = outputTextIsAuthoritative
      ? outputPlainText
      : baseContent;

  if (effectiveContent.trim().isEmpty) {
    return renderStructuredOutputBlocks(outputBlocks);
  }
  if (hasDetails) {
    return renderStructuredOutputBlocksWithContent(
      outputBlocks,
      effectiveContent,
    );
  }
  if (outputTextIsAuthoritative) {
    return renderStructuredOutputBlocks(outputBlocks);
  }
  if (strippedSemanticDetails) {
    if (hasOutputPlainText && !baseContent.contains(outputPlainText)) {
      return renderStructuredOutputBlocks(outputBlocks);
    }
    return renderSemanticMessageBlocks([SemanticTextBlock(baseContent)]);
  }
  return '';
}

String _stripRenderedSemanticDetails(String content) {
  if (!content.contains('<details')) {
    return content;
  }
  final semanticDetailsPattern = RegExp(
    r'''<details\b(?=[^>]*\btype\s*=\s*["'](?:reasoning|tool_calls|code_interpreter|openai_builtin_tool)["'])[\s\S]*?</details>\s*''',
  );
  return content.replaceAll(semanticDetailsPattern, '').trim();
}

String _stringOr(dynamic value, String fallback) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return fallback;
}

/// Safely parse a boolean from various formats (bool, String, int).
bool? _safeBool(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
    return null;
  }
  if (value is num) return value != 0;
  return null;
}

String _synthesizeToolDetailsFromToolCalls(List<Map> calls) {
  return renderSemanticMessageBlocks(
    _semanticToolBlocksFromToolCalls(calls),
  ).trim();
}

List<SemanticMessageBlock> _semanticToolBlocksFromToolCalls(List<Map> calls) {
  final blocks = <SemanticMessageBlock>[];
  for (final rawCall in calls) {
    final call = Map<String, dynamic>.from(rawCall);
    final function = call['function'];
    final name =
        (function is Map ? function['name'] : call['name'])?.toString() ??
        'tool';
    final id =
        (call['id']?.toString() ??
        'call_${DateTime.now().millisecondsSinceEpoch}');
    final done = _safeBool(call['done']) ?? true;
    final argsRaw = function is Map ? function['arguments'] : call['arguments'];
    final resRaw =
        call['result'] ??
        call['output'] ??
        (function is Map ? function['result'] : null);
    blocks.add(
      SemanticDetailsBlock.toolCall(
        id: id,
        name: name,
        arguments: argsRaw,
        done: done,
        result: resRaw,
      ),
    );
  }
  return blocks;
}

String _synthesizeToolDetailsFromToolCallsWithResults(
  List<Map> calls,
  List<Map> results,
) {
  return renderSemanticMessageBlocks(
    _semanticToolBlocksFromToolCallsWithResults(calls, results),
  ).trim();
}

List<SemanticMessageBlock> _semanticToolBlocksFromToolCallsWithResults(
  List<Map> calls,
  List<Map> results,
) {
  final blocks = <SemanticMessageBlock>[];
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
    final embedsRaw = resultEntry != null ? resultEntry['embeds'] : null;

    blocks.add(
      SemanticDetailsBlock.toolCall(
        id: id,
        name: name,
        arguments: argsRaw,
        done: resultEntry != null,
        result: resRaw,
        files: filesRaw,
        embeds: embedsRaw,
      ),
    );
  }

  return blocks;
}

String _synthesizeToolDetailsFromContentArray(List<dynamic> content) {
  final blocks = <SemanticMessageBlock>[];
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
      blocks.addAll(
        _semanticToolBlocksFromToolCallsWithResults(calls, results),
      );
      continue;
    }

    if (type == 'tool_call' || type == 'function_call') {
      final name = (item['name'] ?? item['tool'] ?? 'tool').toString();
      final id =
          (item['id']?.toString() ??
          'call_${DateTime.now().millisecondsSinceEpoch}');
      final argsRaw = item['arguments'] ?? item['args'];
      final resStr = item['result'] ?? item['output'] ?? item['response'];
      blocks.add(
        SemanticDetailsBlock.toolCall(
          id: id,
          name: name,
          arguments: argsRaw,
          done: resStr != null,
          result: resStr,
          embeds: item['embeds'],
        ),
      );
    }
  }
  return renderSemanticMessageBlocks(blocks).trim();
}

Conversation parseFullConversationModel(Object? payload) {
  return Conversation.fromJson(
    parseFullConversation(_coerceConversationMap(payload)),
  );
}

List<Conversation> parseConversationSummaryModels(
  Map<String, dynamic> payload,
) {
  final pinned = _coerceConversationCollection(payload['pinned']);
  final archived = _coerceConversationCollection(payload['archived']);
  final regular = _coerceConversationCollection(payload['regular']);

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

  return summaries.map(Conversation.fromJson).toList(growable: false);
}

List<Conversation> parseFolderSummaryModels(Map<String, dynamic> payload) {
  final chats = _coerceConversationCollection(
    payload['chats'] ?? payload['regular'],
  );
  return chats
      .map(parseConversationSummary)
      .map(Conversation.fromJson)
      .toList(growable: false);
}

Conversation parseFullConversationModelWorker(Object? payload) {
  final raw =
      payload is Map<String, dynamic> && payload.containsKey('conversation')
      ? payload['conversation']
      : payload;
  return parseFullConversationModel(raw);
}

List<Conversation> parseConversationSummaryModelsWorker(
  Map<String, dynamic> payload,
) {
  return parseConversationSummaryModels(payload);
}

List<Conversation> parseFolderSummaryModelsWorker(
  Map<String, dynamic> payload,
) {
  return parseFolderSummaryModels(payload);
}

List<Map<String, dynamic>> parseConversationSummariesWorker(
  Map<String, dynamic> payload,
) {
  return parseConversationSummaryModels(
    payload,
  ).map((conversation) => conversation.toJson()).toList(growable: false);
}

Map<String, dynamic> parseFullConversationWorker(Map<String, dynamic> payload) {
  return parseFullConversationModelWorker(payload).toJson();
}

/// Worker function for parsing folder conversation summaries in a background
/// isolate. Takes a list of raw chat data and returns parsed summaries.
List<Map<String, dynamic>> parseFolderSummariesWorker(
  Map<String, dynamic> payload,
) {
  return parseFolderSummaryModels(
    payload,
  ).map((conversation) => conversation.toJson()).toList(growable: false);
}

Map<String, dynamic> _coerceConversationMap(Object? raw) {
  if (raw is Uint8List) {
    return _decodeConversationMapBytes(raw);
  }
  if (raw is List<int>) {
    return _decodeConversationMapBytes(Uint8List.fromList(raw));
  }
  if (raw is String && raw.isNotEmpty) {
    try {
      return _coerceConversationMap(jsonDecode(raw));
    } catch (_) {
      return <String, dynamic>{};
    }
  }
  if (raw is Map<String, dynamic>) {
    return raw;
  }
  if (raw is Map) {
    return _coerceJsonMap(raw);
  }
  return <String, dynamic>{};
}

Map<String, dynamic> _decodeConversationMapBytes(Uint8List bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map) {
      return _coerceJsonMap(decoded);
    }
  } catch (_) {}
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _coerceConversationCollection(dynamic raw) {
  if (raw == null) {
    return const [];
  }
  if (raw is Uint8List) {
    return _decodeConversationCollectionBytes(raw);
  }
  if (raw is String && raw.isNotEmpty) {
    try {
      return _coerceConversationCollection(jsonDecode(raw));
    } catch (_) {
      return const [];
    }
  }
  if (raw is List) {
    if (raw.isEmpty) {
      return const [];
    }
    if (raw.every((entry) => entry is int)) {
      return _decodeConversationCollectionBytes(
        Uint8List.fromList(raw.cast<int>()),
      );
    }
    if (raw.every((entry) => entry is Uint8List || entry is List<int>)) {
      final merged = <Map<String, dynamic>>[];
      for (final page in raw) {
        merged.addAll(_coerceConversationCollection(page));
      }
      return merged;
    }
    return raw.whereType<Map>().map(_coerceJsonMap).toList(growable: false);
  }
  if (raw is Map) {
    final list =
        raw['conversations'] ??
        raw['items'] ??
        raw['results'] ??
        raw['messages'] ??
        raw['chats'];
    if (list is List) {
      return _coerceConversationCollection(list);
    }
  }
  return const [];
}

List<Map<String, dynamic>> _decodeConversationCollectionBytes(Uint8List bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    return _coerceConversationCollection(decoded);
  } catch (_) {
    return const [];
  }
}
