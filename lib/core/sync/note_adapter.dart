import '../database/app_database.dart';
import '../database/daos/notes_dao.dart' show decodeNotePatch;
import '../database/daos/outbox_dao.dart';
import '../database/mappers/note_mapper.dart' show asNs;
import '../database/daos/sync_meta_dao.dart';
import 'note_sync.dart';
import 'sync_entity_adapter.dart';

/// [SyncEntityAdapter] for FLAT-doc notes (CDT-RFC-001 Phase 5, D-11, R-09).
///
/// Owns the note mapper (note_mapper, identity over a flat dict — no child
/// rows) entirely inside [mergeServer]/[fetchRaw]/[pushOp]; the blob-vs-flat-doc
/// difference never reaches the interface. Carries the NANOSECOND clock unit
/// implicitly via [pullOverlap] + each list item's `updatedAt` and the
/// dedicated [watermarkKey]; those NEVER meet the chat (seconds) domain (R-09).
class NoteAdapter implements SyncEntityAdapter {
  NoteAdapter({
    required NotePullSync pull,
    required NotePushSync push,
  })  : _pull = pull,
        _push = push;

  final NotePullSync _pull;
  final NotePushSync _push;

  @override
  String get watermarkKey => SyncMetaDao.kNotesPullWatermarkKey;

  /// NANOSECONDS overlap (R-09). NEVER compared to the chat overlap.
  @override
  int get pullOverlap => kNotePullOverlapNs;

  /// Notes are fetched in a SINGLE unpaged call ([getListPageRaw] returns an
  /// empty list for any page > 1 without a network call), so a sentinel larger
  /// than any realistic note count keeps `runPullFor` from ever requesting a
  /// page 2 — making the single-page contract explicit rather than relying on
  /// the driver's `items.length < listPageSize` escape hatch (which would do one
  /// extra no-op Dart loop when a user has ≥ 60 notes).
  @override
  int get listPageSize => 1 << 30;

  @override
  bool ownsKind(OutboxKind kind) => kind.isNoteKind;

  @override
  Future<List<SyncListItem>> getListPage(int page) async {
    final raw = await _pull.getListPageRaw(page);
    return [
      for (final item in raw) ?_listItem(item),
    ];
  }

  SyncListItem? _listItem(Map<String, dynamic> item) {
    final id = item['id'];
    if (id is! String || id.isEmpty) return null;
    final ns = asNs(item['updated_at']);
    if (ns == null) return null;
    return SyncListItem(id: id, updatedAt: ns, envelope: item);
  }

  @override
  Future<Map<String, dynamic>?> fetchRaw(String id) => _pull.fetchRaw(id);

  @override
  Future<bool> mergeServer(Map<String, dynamic> raw) =>
      _pull.mergeNoteResponse(raw);

  @override
  Future<void> pushOp(OutboxOp op) async {
    final kind = OutboxKind.fromName(op.kind);
    final noteId = op.chatId;
    if (noteId == null) return;
    switch (kind) {
      case OutboxKind.noteCreate:
        await _push.pushNoteCreate(noteId);
      case OutboxKind.noteUpdate:
        await _push.pushNoteUpdate(noteId, decodeNotePatch(op.payload));
      case OutboxKind.noteDelete:
        await _push.pushNoteDelete(noteId);
      case OutboxKind.notePin:
        final payload = decodeNotePatch(op.payload);
        await _push.pushNotePin(noteId, desired: payload['desired'] == true);
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
