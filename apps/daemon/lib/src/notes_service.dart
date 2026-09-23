import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/error/api_error.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart';
import 'package:conduit_core/features/notes/utils/note_quill_delta.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

/// Implements `notes.*` over the core's note providers (M5).
///
/// The same providers mobile uses, so the durable path is the same too:
/// an edit made offline is written with its outbox operation and pushed
/// when the network returns. What the desktop adds is only the editor's
/// format: a note is stored as markdown and edited as Quill ops, and the
/// conversion goes through the Parchment codec mobile's editor uses.
final class NotesService {
  NotesService(this._container, {EventBus? events}) {
    if (events != null) _announceChanges(events);
  }

  final ProviderContainer _container;

  Future<NoteList> list(String query) async {
    final notes = query.trim().isEmpty
        ? await readSettled(_container, notesListProvider.future)
        : await readSettled(_container, filteredNotesProvider(query).future);
    final sorted = <Note>[...notes]
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    final conflicts = await _conflictCopyIds();
    return NoteList(
      notes: <NoteSummary>[
        for (final note in sorted)
          _summarize(note).copyWith(conflictCopy: conflicts.contains(note.id)),
      ],
    );
  }

  /// The notes that are conflict copies. The flag is the row's; the core's
  /// `Note` does not carry it.
  Future<Set<String>> _conflictCopyIds() async {
    final db = _container.read(appDatabaseProvider);
    if (db == null) return const <String>{};
    final rows = await (db.select(
      db.notes,
    )..where((note) => note.isConflictCopy.equals(true))).get();
    return <String>{for (final row in rows) row.id};
  }

  Future<NoteDetail?> get(String id) async {
    // This computer's copy first, when it knows something the server does
    // not yet: a deletion or an edit still waiting in the outbox. Online,
    // the core's reader goes to the server, which would hand back the note
    // as it was before -- reopening a note just edited showed the old text,
    // and a deleted one came back.
    final db = _container.read(appDatabaseProvider);
    if (db != null) {
      final row = await db.notesDao.getNote(id);
      if (row != null && row.deleted) return null;
      if (row != null && (row.dirtyTitle || row.dirtyData || row.dirtyPinned)) {
        return _detail(Note.fromJson(noteRowToServer(row)));
      }
    }
    // Read fresh: the provider caches by id, and a note edited in another
    // window or on another device should not open as it was.
    _container.invalidate(noteByIdProvider(id));
    try {
      final note = await readSettled(_container, noteByIdProvider(id).future);
      return note == null ? null : _detail(note);
    } on Object catch (error) {
      if (_notFound(error)) return null;
      rethrow;
    }
  }

  static NoteDetail _detail(Note note) => NoteDetail(
    summary: _summarize(note),
    ops: quillOpsFromMarkdown(note.markdownContent),
  );

  /// A note the server no longer has: gone, not an error.
  static bool _notFound(Object error) => switch (error) {
    ApiError(type: ApiErrorType.notFound) => true,
    DioException(error: ApiError(type: ApiErrorType.notFound)) => true,
    DioException(response: Response(statusCode: 404)) => true,
    _ => false,
  };

  Future<NoteDetail> save(NoteSave request) async {
    // Settled first. The providers check that the session they started in
    // is still current when their request returns; straight after signing
    // in the account's database is still being certified, appears during
    // that request, and the note was reported as lost to a session change.
    // The list depends on the same database and account, so once it has
    // settled they have too.
    await readSettled(_container, notesListProvider.future);
    final title = request.title.trim();
    final markdown = request.ops == null
        ? null
        : markdownFromQuillOps(request.ops!);
    final Note? saved;
    if (request.id == null) {
      saved = await _container
          .read(noteCreatorProvider.notifier)
          .createNote(title: title, markdownContent: markdown ?? '');
    } else {
      saved = await _container
          .read(noteUpdaterProvider.notifier)
          .updateNote(request.id!, title: title, markdownContent: markdown);
      _container.invalidate(noteByIdProvider(request.id!));
    }
    if (saved == null) {
      // The providers report why in their state, not by throwing.
      final state = request.id == null
          ? _container.read(noteCreatorProvider)
          : _container.read(noteUpdaterProvider);
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        args: <String, String>{
          if (state.error case final error?) 'detail': '$error',
        },
        debugMessage: request.id == null
            ? 'the note could not be created'
            : 'the note could not be saved',
      );
    }
    return NoteDetail(
      summary: _summarize(saved),
      ops: quillOpsFromMarkdown(markdown ?? saved.markdownContent),
    );
  }

  Future<void> delete(String id) async {
    final deleted = await _container
        .read(noteDeleterProvider.notifier)
        .deleteNote(id);
    if (!deleted) {
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the note could not be deleted',
      );
    }
    _container.invalidate(noteByIdProvider(id));
  }

  /// Pins or unpins [id]. A state, not a toggle: the core writes the
  /// wanted value with its outbox operation, so a list that is a moment
  /// stale cannot turn a pin into an unpin.
  Future<NoteSummary> setPinned(String id, {required bool pinned}) async {
    await readSettled(_container, notesListProvider.future);
    final db = _container.read(appDatabaseProvider);
    Note? updated;
    if (db != null) {
      updated = await durablePinNote(
        _container,
        db,
        id: id,
        desiredPinned: pinned,
      );
    } else {
      // No database (reviewer mode): the API toggles, so only when needed.
      final note = await readSettled(_container, noteByIdProvider(id).future);
      if (note == null) {
        throw RpcError(
          code: ConduitErrorCodes.notFound,
          debugMessage: 'no note $id',
        );
      }
      updated = note.isPinned == pinned
          ? note
          : await _container
                .read(notePinTogglerProvider.notifier)
                .togglePin(note);
    }
    _container.invalidate(noteByIdProvider(id));
    if (updated == null) {
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the note could not be pinned',
      );
    }
    return _summarize(updated);
  }

  /// A short title for the note's text, from a model on the server.
  Future<NoteTitle> generateTitle(NoteAi request) async {
    final (api, model, markdown) = await _aiInputs(request);
    final title = await api.generateNoteTitle(markdown, modelId: model);
    if (title == null || title.trim().isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the model returned no title',
      );
    }
    return NoteTitle(title: title.trim());
  }

  /// The note rewritten by a model on the server. Not saved: the editor
  /// shows it, and saves it like any other edit if the user keeps it.
  Future<NoteBody> enhance(NoteAi request) async {
    final (api, model, markdown) = await _aiInputs(request);
    final enhanced = await api.enhanceNoteContent(markdown, modelId: model);
    if (enhanced == null || enhanced.trim().isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the model returned nothing',
      );
    }
    return NoteBody(ops: quillOpsFromMarkdown(enhanced));
  }

  /// The server, the model to ask and the note's markdown.
  ///
  /// The model is the one asked for, else the one selected for chats, else
  /// the server's first -- but never a direct connection's: these requests
  /// go to the server, which cannot reach those.
  Future<(ApiService, String, String)> _aiInputs(NoteAi request) async {
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'sign in to use a model on the server',
      );
    }
    final markdown = markdownFromQuillOps(request.ops).trim();
    if (markdown.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'empty'},
        debugMessage: 'the note has no text',
      );
    }
    bool onServer(String? id) =>
        id != null && id.isNotEmpty && !id.startsWith('direct:');
    var model = onServer(request.model) ? request.model : null;
    final selected = _container.read(selectedModelProvider)?.id;
    model ??= onServer(selected) ? selected : null;
    if (model == null) {
      final models = await readSettled(_container, modelsProvider.future);
      model = models.map((m) => m.id).where(onServer).firstOrNull;
    }
    if (model == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'the server offers no models',
      );
    }
    return (api, model, markdown);
  }

  /// `notes.changed` whenever the list does: an edit here, a sync, another
  /// window.
  void _announceChanges(EventBus events) {
    _container.listen<AsyncValue<List<Note>>>(notesListProvider, (_, next) {
      if (next.hasValue) {
        events.publish(
          ConduitEvents.notesChanged,
          payload: const NotesChanged().toJson(),
        );
      }
    });
  }

  static NoteSummary _summarize(Note note) => NoteSummary(
    id: note.id,
    title: note.title,
    // Open WebUI stamps notes in nanoseconds.
    updatedAtMs: note.updatedAt ~/ 1000000,
    pinned: note.isPinned,
    preview: _preview(note.listPreviewMarkdown),
  );

  static String _preview(String markdown) {
    final text = markdown.trim();
    return text.length <= 200 ? text : '${text.substring(0, 200)}…';
  }
}
