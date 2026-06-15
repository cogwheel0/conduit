import '../database/app_database.dart';
import '../database/daos/notes_dao.dart' show decodeNotePatch;
import '../database/daos/outbox_dao.dart';
import '../database/mappers/note_mapper.dart' show asNs;
import '../database/daos/sync_meta_dao.dart';
import '../utils/debug_logger.dart';
import 'note_sync.dart';
import 'sync_api_client.dart';
import 'sync_entity_adapter.dart';

/// [SyncEntityAdapter] for FLAT-doc notes (CDT-RFC-001 Phase 5, D-11, R-09).
///
/// Owns the note mapper (note_mapper, identity over a flat dict — no child
/// rows) entirely inside [mergeServer]/[fetchRaw]/[pushOp]; the blob-vs-flat-doc
/// difference never reaches the interface. Carries the NANOSECOND clock unit
/// implicitly via [pullOverlap] + each list item's `updatedAt` and the
/// dedicated [watermarkKey]; those NEVER meet the chat (seconds) domain (R-09).
class NoteAdapter implements SyncEntityAdapter, SyncEntityPullPrepare {
  NoteAdapter({required NotePullSync pull, required NotePushSync push})
    : _pull = pull,
      _push = push;

  final NotePullSync _pull;
  final NotePushSync _push;
  bool? _hasPendingCreateHashes;

  @override
  String get watermarkKey => SyncMetaDao.kNotesPullWatermarkKey;

  /// NANOSECONDS overlap (R-09). NEVER compared to the chat overlap.
  @override
  int get pullOverlap => kNotePullOverlapNs;

  /// Vendored `GET /api/v1/notes/?page=N` returns 60 items per page.
  @override
  int get listPageSize => kOpenWebUiNoteListPageSize;

  @override
  // The vendored list endpoint truncates data.content.md to 1000 chars; it is
  // only authoritative for id/updated_at. Always full-fetch changed notes.
  bool get listEnvelopeIsFullRaw => false;

  @override
  bool ownsKind(OutboxKind kind) => kind.isNoteKind;

  @override
  Future<List<SyncListItem>> getListPage(int page) async {
    final raw = await _pull.getListPageRaw(page);
    return [for (final item in raw) _listItem(item)];
  }

  SyncListItem _listItem(Map<String, dynamic> item) {
    final id = item['id'];
    if (id is! String || id.isEmpty) {
      _logMalformedListItem(reason: 'missing-id');
      return const SyncListItem.skip();
    }
    final ns = asNs(item['updated_at']);
    if (ns == null) {
      _logMalformedListItem(reason: 'missing-updated-at', id: id);
      return const SyncListItem.skip();
    }
    return SyncListItem(id: id, updatedAt: ns, envelope: item);
  }

  void _logMalformedListItem({required String reason, String? id}) {
    DebugLogger.warning(
      'skip-malformed-note-list-item',
      scope: 'sync/notes',
      data: {'reason': reason, 'noteId': id},
    );
  }

  @override
  Future<Map<String, dynamic>?> fetchRaw(String id) => _pull.fetchRaw(id);

  @override
  Future<void> preparePull() async {
    _hasPendingCreateHashes = await _pull.hasPendingCreateContentHashes();
  }

  @override
  Future<bool> mergeServer(Map<String, dynamic> raw) => _pull.mergeNoteResponse(
    raw,
    hasPendingCreateHashes: _hasPendingCreateHashes,
  );

  @override
  Future<void> pushOp(OutboxOp op) async {
    final kind = OutboxKind.fromName(op.kind);
    final noteId = op.chatId;
    if (kind != null && kind.isNoteKind && (noteId == null || noteId.isEmpty)) {
      throw SyncTerminalException(
        statusCode: 400,
        message: 'malformed ${kind.name} op: missing noteId',
      );
    }
    if (noteId == null) return;
    switch (kind) {
      case OutboxKind.noteCreate:
        await _push.pushNoteCreate(noteId);
        break;
      case OutboxKind.noteUpdate:
        await _push.pushNoteUpdate(noteId, decodeNotePatch(op.payload));
        break;
      case OutboxKind.noteDelete:
        await _push.pushNoteDelete(noteId);
        break;
      case OutboxKind.notePin:
        final payload = decodeNotePatch(op.payload);
        await _push.pushNotePin(noteId, desired: payload['desired'] == true);
        break;
      // Not owned (drainer never routes these here).
      case OutboxKind.createChat:
      case OutboxKind.updateChat:
      case OutboxKind.deleteChat:
      case OutboxKind.requestCompletion:
      case OutboxKind.folderUpsert:
      case OutboxKind.folderDelete:
      case null:
        return;
    }
  }
}
