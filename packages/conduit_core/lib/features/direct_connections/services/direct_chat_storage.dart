import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/utils/openwebui_message_payload.dart';
import 'package:conduit_core/utils/persisted_message_content.dart';

/// How a direct-provider chat is written to the local database.
///
/// Lifted out of the mobile app, where these were private to its send
/// path, so the desktop daemon writes direct chats the same way: the same
/// message payload, the same blob for a new chat, and so the same shape
/// the sync engine pushes to Open WebUI when history is mirrored there.

/// A message as Open WebUI stores it in a chat's history, with the
/// transport marker that says which backend answered.
Map<String, dynamic> directPersistedMessagePayload(
  ChatMessage message, {
  required String? parentId,
  required List<String> childrenIds,
  String? assistantTransport = kDirectTransport,
}) {
  final metadata = <String, dynamic>{
    ...?message.metadata,
    if (message.role == 'assistant' && assistantTransport != null)
      'transport': assistantTransport,
  };
  return <String, dynamic>{
    'id': message.id,
    'parentId': parentId,
    'childrenIds': childrenIds,
    'role': message.role,
    'content': persistedMessageContent(message),
    'isStreaming': message.isStreaming,
    if (message.role == 'assistant' && !message.isStreaming) 'done': true,
    if (message.model != null) 'model': message.model,
    if (metadata['modelName'] != null) 'modelName': metadata['modelName'],
    if (message.attachmentIds?.isNotEmpty == true)
      'attachment_ids': List<String>.from(message.attachmentIds!),
    if (sanitizeFilesForWebUi(message.files) != null)
      'files': sanitizeFilesForWebUi(message.files),
    if (message.output != null) 'output': message.output,
    if (message.embeds != null) 'embeds': message.embeds,
    if (message.statusHistory.isNotEmpty)
      'statusHistory': message.statusHistory
          .map((status) => status.toJson())
          .toList(growable: false),
    if (message.followUps.isNotEmpty)
      'followUps': List<String>.from(message.followUps),
    if (message.codeExecutions.isNotEmpty)
      'code_executions': convertCodeExecutionsToOpenWebUIFormat(
        message.codeExecutions,
      ),
    if (message.sources.isNotEmpty)
      'sources': convertSourcesToOpenWebUIFormat(message.sources),
    if (message.usage != null) 'usage': message.usage,
    if (message.versions.isNotEmpty)
      'versions': message.versions
          .map((version) => version.toJson())
          .toList(growable: false),
    if (message.error != null) 'error': message.error!.toJson(),
    if (metadata.isNotEmpty) 'metadata': metadata,
    'timestamp': message.timestamp.millisecondsSinceEpoch ~/ 1000,
  };
}

/// One message row for [ChatDatabaseRepository.persistDirectMessages].
MessageRowData directMessageRow({
  required String chatId,
  required ChatMessage message,
  required String? parentId,
  required List<String> childrenIds,
  required int orderIndex,
  String? assistantTransport = kDirectTransport,
}) {
  return MessageRowData(
    id: message.id,
    chatId: chatId,
    parentId: parentId,
    role: message.role,
    content: persistedMessageContent(message),
    model: message.model,
    createdAt: message.timestamp.millisecondsSinceEpoch ~/ 1000,
    orderIndex: orderIndex,
    payload: directPersistedMessagePayload(
      message,
      parentId: parentId,
      childrenIds: childrenIds,
      assistantTransport: assistantTransport,
    ),
  );
}

/// The blob for a new direct chat: a linear history ending at the last
/// message.
Map<String, dynamic> directNewChatBlob({
  required String title,
  required String modelId,
  required List<ChatMessage> messages,
}) {
  final messageMap = <String, dynamic>{};
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    final parentId = index == 0 ? null : messages[index - 1].id;
    final childrenIds = index + 1 < messages.length
        ? <String>[messages[index + 1].id]
        : const <String>[];
    messageMap[message.id] = directPersistedMessagePayload(
      message,
      parentId: parentId,
      childrenIds: childrenIds,
    );
  }
  return <String, dynamic>{
    'title': title,
    'models': <String>[modelId],
    'conduit': const <String, dynamic>{'backend': kDirectTransport},
    'history': <String, dynamic>{
      'currentId': messages.lastOrNull?.id,
      'messages': messageMap,
    },
  };
}
