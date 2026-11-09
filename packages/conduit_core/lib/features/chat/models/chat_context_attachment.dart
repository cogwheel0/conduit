import 'package:meta/meta.dart';

/// Represents a non-file attachment that enriches a chat message,
/// such as a web page, YouTube video transcript, existing note,
/// or knowledge base document reference.
@immutable
class ChatContextAttachment {
  const ChatContextAttachment({
    required this.id,
    required this.type,
    required this.displayName,
    this.url,
    this.content,
    this.collectionName,
    this.fileId,
  });

  /// A whole knowledge base, as Open WebUI's own client attaches one: the
  /// model draws on every file in it. The phone attaches single files from a
  /// base instead ([ChatContextAttachmentType.knowledge] with a [fileId]);
  /// a client whose `#` picks a whole base sends this. [description]
  /// travels with it, as the web client sends it.
  const ChatContextAttachment.knowledgeBase({
    required this.id,
    required String name,
    String? description,
  }) : type = ChatContextAttachmentType.knowledge,
       displayName = name,
       url = null,
       content = description,
       collectionName = null,
       fileId = null;

  final String id;
  final ChatContextAttachmentType type;
  final String displayName;
  final String? url;
  final String? content;
  final String? collectionName;
  final String? fileId;

  /// Whether this is a whole knowledge base rather than one file from it.
  bool get isKnowledgeBase =>
      type == ChatContextAttachmentType.knowledge && fileId == null;
}

enum ChatContextAttachmentType { web, youtube, knowledge, note }
