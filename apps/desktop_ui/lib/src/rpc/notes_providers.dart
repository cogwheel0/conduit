import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../note_editor.dart';
import 'rpc_providers.dart';

/// The notes editor, overridden in `main.dart` with Quill.
final noteEditorProvider = Provider<NoteEditorPort>(
  (ref) => RecordingNoteEditor(),
);

/// The notes list's search text.
final noteSearchProvider = NotifierProvider<NoteSearch, String>(NoteSearch.new);

class NoteSearch extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) => state = query;
}

/// Ticks on `notes.changed`: an edit here, in another window, or a sync.
final _notesChangedProvider = StreamProvider<int>((ref) {
  var tick = 0;
  return ref
      .watch(rpcClientProvider)
      .events
      .where((envelope) => envelope.event == ConduitEvents.notesChanged)
      .map((_) => ++tick);
});

/// The notes, pinned first, filtered by [noteSearchProvider].
final noteListProvider = FutureProvider<NoteList>((ref) async {
  ref.watch(coreConnectionProvider);
  ref.watch(_notesChangedProvider);
  final query = ref.watch(noteSearchProvider);
  return ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.notesList,
        params: NoteQuery(query: query).toJson(),
        decode: NoteList.fromJson,
      );
});

/// One note to edit, or null when it no longer exists.
///
/// Not refetched on `notes.changed`: the editor showing it is where the
/// change came from, most of the time, and replacing its contents under
/// the cursor would lose what was typed since.
final noteDetailProvider = FutureProvider.family<NoteDetail?, String>((
  ref,
  id,
) async {
  ref.watch(coreConnectionProvider);
  final raw = await ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.notesGet,
        params: NoteRef(id: id).toJson(),
        decode: (json) => json,
      );
  final note = raw['note'];
  return note == null
      ? null
      : NoteDetail.fromJson(note as Map<String, dynamic>);
});

final noteActionsProvider = Provider<NoteActions>(NoteActions.new);

class NoteActions {
  NoteActions(this._ref);

  final Ref _ref;

  Future<NoteDetail> save(NoteSave note) async {
    final saved = await _ref
        .read(rpcClientProvider)
        .call(
          ConduitMethods.notesSave,
          params: note.toJson(),
          decode: NoteDetail.fromJson,
        );
    _ref.invalidate(noteListProvider);
    return saved;
  }

  Future<void> delete(String id) async {
    await _ref
        .read(rpcClientProvider)
        .call(
          ConduitMethods.notesDelete,
          params: NoteRef(id: id).toJson(),
          decode: (json) => json,
        );
    _ref
      ..invalidate(noteListProvider)
      ..invalidate(noteDetailProvider(id));
  }

  /// A title for [ops] from a model on the server.
  Future<String> generateTitle(List<Map<String, dynamic>> ops) async {
    final title = await _ref
        .read(rpcClientProvider)
        .call(
          ConduitMethods.notesGenerateTitle,
          params: NoteAi(ops: ops).toJson(),
          decode: NoteTitle.fromJson,
        );
    return title.title;
  }

  /// [ops] rewritten by a model on the server; not saved.
  Future<List<Map<String, dynamic>>> enhance(
    List<Map<String, dynamic>> ops,
  ) async {
    final body = await _ref
        .read(rpcClientProvider)
        .call(
          ConduitMethods.notesEnhance,
          params: NoteAi(ops: ops).toJson(),
          decode: NoteBody.fromJson,
        );
    return body.ops;
  }

  Future<NoteDetail> attach(String noteId, NoteFile file) => _ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.notesAttach,
        params: NoteAttach(noteId: noteId, file: file).toJson(),
        decode: NoteDetail.fromJson,
      );

  Future<NoteDetail> detach(String noteId, String fileId) => _ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.notesDetach,
        params: NoteDetach(noteId: noteId, fileId: fileId).toJson(),
        decode: NoteDetail.fromJson,
      );

  Future<void> setPinned(String id, {required bool pinned}) async {
    await _ref
        .read(rpcClientProvider)
        .call(
          ConduitMethods.notesSetPinned,
          params: NotePin(id: id, pinned: pinned).toJson(),
          decode: NoteSummary.fromJson,
        );
    _ref.invalidate(noteListProvider);
  }
}
