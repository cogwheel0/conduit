import '../models/chat_message.dart';

/// Returns a trimmed message id, or `null` when the value is blank.
String? normalizeMessageId(Object? value) {
  final id = value?.toString().trim();
  if (id == null || id.isEmpty) {
    return null;
  }
  return id;
}

/// Coerces OpenWebUI-style id lists into normalized message ids.
List<String> coerceMessageIdList(Object? value) {
  if (value is! Iterable) {
    return const <String>[];
  }

  return value.map(normalizeMessageId).nonNulls.toList(growable: false);
}

/// Builds a lookup of normalized child ids grouped by parent id.
Map<String, List<String>> buildChildrenByParent<T>(
  Iterable<T> messages, {
  required String? Function(T message) idOf,
  required String? Function(T message) parentIdOf,
}) {
  final childrenByParent = <String, List<String>>{};
  for (final message in messages) {
    final id = idOf(message);
    final parentId = parentIdOf(message);
    if (id == null || parentId == null) {
      continue;
    }
    childrenByParent.putIfAbsent(parentId, () => <String>[]).add(id);
  }
  return childrenByParent;
}

/// Collects a message id and all descendants using an existing child lookup.
Set<String> collectDescendantIds(
  String messageId,
  Map<String, List<String>> childrenByParent,
) {
  final rootId = normalizeMessageId(messageId);
  if (rootId == null) {
    return const <String>{};
  }

  final result = <String>{};
  final pending = <String>[rootId];
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (result.add(id)) {
      pending.addAll(childrenByParent[id] ?? const <String>[]);
    }
  }
  return result;
}

/// Walks from [currentId] to the root by following parent ids.
List<T> chainToRoot<T>(
  String currentId, {
  required Map<String, T> messagesById,
  required String? Function(T message) parentIdOf,
}) {
  final chain = <T>[];
  final visited = <String>{};
  var nextId = normalizeMessageId(currentId);

  while (nextId != null && visited.add(nextId)) {
    final message = messagesById[nextId];
    if (message == null) {
      break;
    }
    chain.add(message);
    nextId = parentIdOf(message);
  }

  return chain.reversed.toList(growable: false);
}

/// Finds same-role sibling messages for an item in a message tree.
List<T> sameRoleSiblings<T>({
  required String messageId,
  required T message,
  required Map<String, T> messagesById,
  required String? Function(T message) parentIdOf,
  required Iterable<String> Function(T message) childrenIdsOf,
  required String? Function(T message) roleOf,
}) {
  final id = normalizeMessageId(messageId);
  final parentId = parentIdOf(message);
  final role = roleOf(message);
  if (id == null || parentId == null || role == null) {
    return <T>[];
  }

  final parent = messagesById[parentId];
  if (parent == null) {
    return <T>[];
  }

  final siblings = <T>[];
  for (final siblingId in childrenIdsOf(parent)) {
    if (siblingId == id) {
      continue;
    }
    final sibling = messagesById[siblingId];
    if (sibling != null && roleOf(sibling) == role) {
      siblings.add(sibling);
    }
  }
  return siblings;
}

/// Returns the newest remaining message id using OpenWebUI timestamps.
String? latestRemainingMessageId<T>(
  Map<String, T> messagesById, {
  required num? Function(T message) timestampOf,
}) {
  String? latestId;
  num? latestTimestamp;
  String? fallbackId;

  for (final entry in messagesById.entries) {
    final timestamp = timestampOf(entry.value);
    if (timestamp == null) {
      fallbackId = entry.key;
      continue;
    }
    if (latestTimestamp == null || timestamp >= latestTimestamp) {
      latestId = entry.key;
      latestTimestamp = timestamp;
    }
  }

  return latestId ?? fallbackId;
}

/// Reads a `ChatMessage` parent id from metadata.
String? chatMessageParentId(ChatMessage message) =>
    normalizeMessageId(message.metadata?['parentId']);

/// Reads `ChatMessage` child ids from metadata.
List<String> chatMessageChildrenIds(ChatMessage message) =>
    coerceMessageIdList(message.metadata?['childrenIds']);

/// Builds a lookup of chat messages by id.
Map<String, ChatMessage> chatMessagesById(Iterable<ChatMessage> messages) {
  return <String, ChatMessage>{
    for (final message in messages) ?normalizeMessageId(message.id): message,
  };
}

/// Builds a parent-to-children lookup for chat messages.
Map<String, List<String>> chatMessageChildrenByParent(
  Iterable<ChatMessage> messages,
) {
  return buildChildrenByParent<ChatMessage>(
    messages,
    idOf: (message) => normalizeMessageId(message.id),
    parentIdOf: chatMessageParentId,
  );
}

/// Collects a chat message id and descendants using `ChatMessage` metadata.
Set<String> chatMessageDescendantIds(
  Iterable<ChatMessage> messages,
  String messageId,
) {
  return collectDescendantIds(messageId, chatMessageChildrenByParent(messages));
}

/// Resolves the user parent for an assistant, falling back to earlier users.
String? assistantParentUserMessageId({
  required List<ChatMessage> messages,
  required int assistantIndex,
}) {
  if (assistantIndex < 0 || assistantIndex >= messages.length) {
    return null;
  }

  final parentId = chatMessageParentId(messages[assistantIndex]);
  if (parentId != null) {
    return parentId;
  }

  for (var index = assistantIndex - 1; index >= 0; index--) {
    final message = messages[index];
    if (message.role == 'user') {
      return message.id;
    }
  }
  return null;
}

/// Coerces OpenWebUI history messages into a normalized map.
Map<String, Map<String, dynamic>> coerceRawMessageMap(Object? value) {
  if (value is! Map) {
    return const <String, Map<String, dynamic>>{};
  }

  final messages = <String, Map<String, dynamic>>{};
  value.forEach((key, rawMessage) {
    final id = normalizeMessageId(key);
    if (id == null || rawMessage is! Map) {
      return;
    }
    messages[id] = coerceRawJsonMap(rawMessage)..['id'] = id;
  });
  return messages;
}

/// Coerces a raw JSON-like map into a `Map<String, dynamic>`.
Map<String, dynamic> coerceRawJsonMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  if (value is Map) {
    final result = <String, dynamic>{};
    value.forEach((key, item) {
      result[key.toString()] = item;
    });
    return result;
  }
  return <String, dynamic>{};
}

/// Reads an OpenWebUI parent id from a raw history message.
String? rawMessageParentId(Map<String, dynamic> message) =>
    normalizeMessageId(message['parentId']);

/// Reads OpenWebUI child ids from a raw history message.
List<String> rawMessageChildrenIds(Map<String, dynamic> message) =>
    coerceMessageIdList(message['childrenIds']);

/// Reads an OpenWebUI role from a raw history message.
String? rawMessageRole(Map<String, dynamic> message) =>
    normalizeMessageId(message['role']);
