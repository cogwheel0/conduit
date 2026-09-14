import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/models/conversation.dart';
import '../../../core/models/folder.dart';
import '../../../core/models/shared_folder_chat.dart';
import '../../../core/providers/app_providers.dart';

part 'shared_folders_providers.g.dart';

/// Folders owned by another user and shared with the current one (the web
/// UI's "Shared" sidebar section). Unlike [foldersProvider], this is a plain
/// network read with no local persistence and no sync-engine involvement:
/// shared folders are read-only from the current user's perspective (see
/// `SharedFolderChat`), so there's nothing here that needs offline mutation
/// support or an outbox. `refresh()` re-fetches; the drawer calls it
/// alongside `foldersProvider.notifier.refresh()` on pull-to-refresh.
@Riverpod(keepAlive: true)
class SharedFolders extends _$SharedFolders {
  @override
  Future<List<Folder>> build() async {
    final api = ref.watch(apiServiceProvider);
    if (api == null) {
      return const <Folder>[];
    }
    final raw = await api.getSharedFolders();
    return [for (final json in raw) Folder.fromJson(json)];
  }

  Future<void> refresh() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData<List<Folder>>(<Folder>[]);
      return;
    }
    try {
      final raw = await api.getSharedFolders();
      state = AsyncData<List<Folder>>([
        for (final json in raw) Folder.fromJson(json),
      ]);
    } catch (error, stackTrace) {
      state = AsyncError<List<Folder>>(error, stackTrace);
    }
  }
}

/// The chats inside one shared folder, fetched live (no caching beyond
/// Riverpod's own provider lifetime) since there's no local copy to read
/// from. `folder_page`'s owned-folder equivalent
/// (`folderConversationSummariesProvider`) reads through the local
/// database instead; this one always hits the network because these chats
/// are never synced locally.
@riverpod
Future<List<SharedFolderChat>> sharedFolderChats(
  Ref ref,
  String folderId,
) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return const <SharedFolderChat>[];
  }
  final raw = await api.getSharedFolderChats(folderId);
  return [for (final json in raw) SharedFolderChat.fromJson(json)];
}

/// Full message content for one chat opened from the "Shared" section.
/// Reuses [ApiService.getConversation] (`GET /api/v1/chats/{id}`) as-is —
/// the backend already grants read access to any chat inside a folder the
/// caller has folder-read access to (see `Chats.get_chat_by_id_for_user` in
/// `open_webui`), so no new backend surface is needed to fetch content, only
/// to discover which chats exist in someone else's folder in the first
/// place (`sharedFolderChatsProvider` above).
@riverpod
Future<Conversation> sharedChatDetail(Ref ref, String chatId) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    throw StateError('Not authenticated');
  }
  return api.getConversation(chatId);
}
