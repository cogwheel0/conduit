import 'dart:convert';

import '../database/app_database.dart';
import '../database/daos/outbox_dao.dart';
import 'chat_locks.dart';
import 'pull_sync.dart';
import 'push_sync.dart';
import 'sync_entity_adapter.dart';

/// `sync_meta` key for the chat pull watermark (epoch SECONDS). R-09: NEVER
/// read against the note `notes_pull_watermark` (nanoseconds).
const String kChatPullWatermarkKey = 'pull_watermark';

/// [SyncEntityAdapter] for blob-model chats (CDT-RFC-001 Phase 5 seam,
/// extracted alongside [NoteAdapter] from the two real impls).
///
/// Owns `ChatBlobMapper.blobToRows` (the §6.1 round-trip invariant, blob →
/// child rows) entirely inside [mergeServer] via [PullSync]; the blob-vs-flat
/// divergence never reaches the interface. Carries the SECONDS clock unit
/// implicitly via [pullOverlap] + each list item's `updatedAt` + the dedicated
/// [watermarkKey].
///
/// SCOPE: this adapter exposes the GENUINELY-shared chat surface — the main
/// list, full fetch, three-way merge, and outbox push. The chat-only axes
/// (archived sub-loop, folders, createChat crash-heal) are NOT modeled here;
/// they stay in [PullSync.run]'s concrete orchestrator (see the seam caveat in
/// `sync_entity_adapter.dart`). The drainer routes chat push ops through
/// [pushOp]; the engine drives chat PULL through [PullSync.run] (not the
/// generic `runPullFor`) so the archived/folders coupling is preserved.
class ChatAdapter implements SyncEntityAdapter {
  ChatAdapter({
    required PullSync pull,
    required PushSync push,
    required ChatLocks chatLocks,
  })  : _pull = pull,
        _push = push,
        _locks = chatLocks;

  final PullSync _pull;
  final PushSync _push;
  final ChatLocks _locks;

  @override
  String get watermarkKey => kChatPullWatermarkKey;

  /// SECONDS overlap (R-09). NEVER compared to the note overlap.
  @override
  int get pullOverlap => kPullOverlapSeconds;

  @override
  ChatLocks get locks => _locks;

  @override
  int get listPageSize => kOpenWebUiChatListPageSize;

  @override
  bool ownsKind(OutboxKind kind) =>
      kind == OutboxKind.createChat ||
      kind == OutboxKind.updateChat ||
      kind == OutboxKind.deleteChat ||
      kind == OutboxKind.requestCompletion ||
      kind.isFolderKind;

  @override
  Future<List<SyncListItem>> getListPage(int page) => _pull.mainListPage(page);

  @override
  Future<Map<String, dynamic>?> fetchRaw(String id) => _pull.fetchChatRaw(id);

  @override
  Future<bool> mergeServer(Map<String, dynamic> raw) =>
      _pull.mergeChatResponseForAdapter(raw);

  @override
  Future<void> pushOp(OutboxOp op) async {
    final kind = OutboxKind.fromName(op.kind);
    switch (kind) {
      case OutboxKind.createChat:
        await _push.pushCreateChat(op.chatId!);
      case OutboxKind.updateChat:
        await _push.pushUpdateChat(op.chatId!);
      case OutboxKind.deleteChat:
        await _push.pushDeleteChat(op.chatId!);
      case OutboxKind.folderUpsert:
        await _push.pushFolderUpsert(_decodePayload(op.payload));
      case OutboxKind.folderDelete:
        await _push.pushFolderDelete(
          _decodePayload(op.payload)['folderId'] as String,
        );
      // requestCompletion is chat-only but has NO push handler here — the
      // drainer runs it via its RequestCompletionRunner seam, not pushOp. Note
      // kinds are not owned. null is an unknown/legacy kind.
      case OutboxKind.requestCompletion:
      case OutboxKind.noteCreate:
      case OutboxKind.noteUpdate:
      case OutboxKind.noteDelete:
      case OutboxKind.notePin:
      case null:
        return;
    }
  }

  static Map<String, dynamic> _decodePayload(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    return <String, dynamic>{};
  }
}
