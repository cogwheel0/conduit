import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_context_attachment.dart';
import '../services/url_context.dart';

class ContextAttachmentsNotifier extends Notifier<List<ChatContextAttachment>> {
  @override
  List<ChatContextAttachment> build() => const [];

  void add(ChatContextAttachment attachment) {
    state = [...state, attachment];
  }

  void addWeb({
    required String displayName,
    required String content,
    required String url,
    String? collectionName,
  }) {
    final id = const Uuid().v4();
    add(
      ChatContextAttachment(
        id: id,
        type: ChatContextAttachmentType.web,
        displayName: displayName,
        url: url,
        content: content,
        collectionName: collectionName,
      ),
    );
  }

  void addYoutube({
    required String displayName,
    required String content,
    required String url,
    String? collectionName,
  }) {
    final id = const Uuid().v4();
    add(
      ChatContextAttachment(
        id: id,
        type: ChatContextAttachmentType.youtube,
        displayName: displayName,
        url: url,
        content: content,
        collectionName: collectionName,
      ),
    );
  }

  /// Attaches what [readUrlContext] read: a transcript or a page.
  void addUrlContext(UrlContext page) {
    if (page.youtube) {
      addYoutube(
        displayName: page.displayName,
        content: page.content,
        url: page.url,
        collectionName: page.collectionName,
      );
    } else {
      addWeb(
        displayName: page.displayName,
        content: page.content,
        url: page.url,
        collectionName: page.collectionName,
      );
    }
  }

  void addKnowledge({
    required String displayName,
    required String fileId,
    String? collectionName,
    String? url,
  }) {
    final id = const Uuid().v4();
    add(
      ChatContextAttachment(
        id: id,
        type: ChatContextAttachmentType.knowledge,
        displayName: displayName,
        fileId: fileId,
        url: url,
        collectionName: collectionName,
      ),
    );
  }

  void addNote({required String noteId, required String displayName}) {
    final alreadyAttached = state.any(
      (attachment) =>
          attachment.type == ChatContextAttachmentType.note &&
          attachment.id == noteId,
    );
    if (alreadyAttached) {
      return;
    }

    add(
      ChatContextAttachment(
        id: noteId,
        type: ChatContextAttachmentType.note,
        displayName: displayName,
      ),
    );
  }

  void remove(String id) {
    state = state.where((item) => item.id != id).toList();
  }

  void clear() {
    state = const [];
  }
}

final contextAttachmentsProvider =
    NotifierProvider<ContextAttachmentsNotifier, List<ChatContextAttachment>>(
      ContextAttachmentsNotifier.new,
    );
