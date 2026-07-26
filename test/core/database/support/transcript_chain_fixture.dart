import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';

/// Builds a deterministic, single-branch transcript for database tests.
ChatRows buildLinearChatRows({
  required String chatId,
  required int count,
  String title = 'Window',
  String Function(int index)? messageIdForIndex,
  String Function(int index)? contentForIndex,
  int Function(int index)? createdAtForIndex,
  int chatCreatedAt = 1,
  int chatUpdatedAt = 2,
  List<MessageRowData> extras = const [],
}) {
  final idAt = messageIdForIndex ?? (index) => 'm$index';
  final contentAt = contentForIndex ?? (index) => 'message $index';
  final createdAt = createdAtForIndex ?? (_) => 100;
  final messages = <MessageRowData>[
    for (var index = 0; index < count; index += 1)
      MessageRowData(
        id: idAt(index),
        chatId: chatId,
        parentId: index == 0 ? null : idAt(index - 1),
        role: index.isEven ? 'user' : 'assistant',
        content: contentAt(index),
        createdAt: createdAt(index),
        orderIndex: index,
        payload: {
          'id': idAt(index),
          'parentId': index == 0 ? null : idAt(index - 1),
          'role': index.isEven ? 'user' : 'assistant',
          'content': contentAt(index),
          'timestamp': createdAt(index),
        },
      ),
    ...extras,
  ];
  return ChatRows(
    chat: ChatRowData(
      id: chatId,
      title: title,
      currentMessageId: count == 0 ? null : idAt(count - 1),
      createdAt: chatCreatedAt,
      updatedAt: chatUpdatedAt,
    ),
    messages: messages,
    blobHadTitle: true,
    blobTitleValue: title,
    blobHadHistory: true,
    historyHadMessages: true,
    historyHadCurrentId: true,
  );
}
