import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/error/api_error.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show currentUserProvider2;
import 'package:conduit_core/features/notes/providers/notes_providers.dart';
import 'package:conduit_core/features/notes/services/deleted_note_draft_recovery.dart';
import 'package:conduit_core/features/notes/services/note_attachments_controller.dart';
import 'package:conduit_core/features/notes/services/note_audio_upload_service.dart';
import 'package:conduit_core/features/notes/utils/note_access.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:conduit_core/features/notes/utils/note_page_entries.dart';
import 'package:conduit_core/features/notes/utils/note_persistence.dart';
import 'package:conduit_core/features/notes/utils/note_quill_delta.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart'
    show currentPreferenceAccountId;
import 'package:conduit_core/ports/paths_port.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:riverpod/riverpod.dart';

import 'account_scope.dart';
import 'event_bus.dart';
import 'settled.dart';

/// Implements `notes.*` over the core's note providers.
///
/// The same providers mobile uses, so the durable path is the same too:
/// an edit made offline is written with its outbox operation and pushed
/// when the network returns. What the desktop adds is only the editor's
/// format: a note is stored as markdown and edited as Quill ops, and the
/// conversion goes through the Parchment codec mobile's editor uses.
///
/// Pages, the file-link merge, refusals and the recovery of a deleted
/// note's draft follow the phone's editor: a save goes to the page the
/// editor shows through the core's `persistNoteUpdate`, a refusal leaves
/// the text with the editor, and a note the server deleted is kept as a
/// new note ([createNoteFromDeletedDraft]). Recordings go through the
/// core's [NoteAttachmentsController], one per note asked about.
final class NotesService {
  NotesService(this._container, {EventBus? events, PathsPort? paths})
    : _events = events,
      _audioStore = paths == null
          ? null
          : NoteAudioUploadStore.withPaths(paths) {
    if (events != null) _announceChanges(events);
  }

  final ProviderContainer _container;
  final EventBus? _events;

  /// Where recordings wait until the server has them; none in tests that
  /// do not record.
  final NoteAudioUploadStore? _audioStore;

  /// The notes handed to an editor, by id: what a deleted note's draft is
  /// recovered over.
  final Map<String, Note> _seen = <String, Note>{};

  /// The account (active server) each note in [_seen] was handed out
  /// under: a draft is recovered only under that account, never into the
  /// next one's notes.
  final Map<String, String?> _seenUnder = <String, String?>{};

  /// One recordings controller per note asked about.
  final Map<String, _NoteRecorder> _recorders = <String, _NoteRecorder>{};

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
    final access = await _access();
    return NoteList(
      notes: <NoteSummary>[
        for (final note in sorted)
          _summarize(
            note,
            access,
          ).copyWith(conflictCopy: conflicts.contains(note.id)),
      ],
    );
  }

  /// Who is asking, and whether the server lets them share notes: what
  /// each summary's access flags depend on.
  Future<_Access> _access() async {
    final accountId = _container.read(currentUserProvider2)?.id;
    var sharing = false;
    try {
      final caps = await readSettled(
        _container,
        workspaceCapabilitiesProvider.future,
      ).timeout(const Duration(milliseconds: 1500));
      sharing = caps.notes.section.share;
    } on Object {
      // Unknown (offline, or another backend): Share Access is not offered.
    }
    return (accountId: accountId, sharing: sharing);
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

  Future<NoteDetail?> get(String requested, {String? pageId}) async {
    var id = requested;
    // This computer's copy first, when it knows something the server does
    // not yet: a deletion or an edit still waiting in the outbox. Online,
    // the core's reader goes to the server, which would hand back the note
    // as it was before -- reopening a note just edited showed the old text,
    // and a deleted one came back.
    // The account it is read under, with its database: a read answered
    // after another account became active is refused, never shown or
    // remembered as that account's.
    final account = AccountScope.capture(_container);
    final scope = account.preferenceAccount;
    final db = _container.read(appDatabaseProvider);
    final access = await _access();
    if (db != null) {
      // A note made here (a `local:` id) the outbox has since created on
      // the server goes by the server's id: answered under it, so the
      // editor follows (the phone's editor resolves it the same way).
      id = await db.notesDao.resolveNoteRemapTarget(id);
      final row = await db.notesDao.getNote(id);
      if (row != null && row.deleted) return null;
      if (row != null && (row.dirtyTitle || row.dirtyData || row.dirtyPinned)) {
        account.require('note $id was read');
        return _detail(
          Note.fromJson(noteRowToServer(row)),
          access,
          pageId: pageId,
          scope: scope,
        );
      }
    }
    // Read fresh: the provider caches by id, and a note edited in another
    // window or on another device should not open as it was.
    _container.invalidate(noteByIdProvider(id));
    try {
      final note = await readSettled(_container, noteByIdProvider(id).future);
      account.require('note $id was read');
      return note == null
          ? null
          : _detail(note, access, pageId: pageId, scope: scope);
    } on Object catch (error) {
      if (_notFound(error)) return null;
      rethrow;
    }
  }

  /// The note as the editor shows page [pageId] of it (the main page when
  /// it has no such page), remembered for a recovery.
  ///
  /// [scope]: the account it was read or written under (the active one when
  /// not given).
  NoteDetail _detail(
    Note note,
    _Access access, {
    String? pageId,
    String? scope,
  }) {
    _seen[note.id] = note;
    _seenUnder[note.id] = scope ?? currentPreferenceAccountId();
    final page = _pageOf(note, pageId);
    final markdown = _pageMarkdown(note, page);
    final files = <NoteFile>[
      for (final file in note.data.files ?? const <Map<String, dynamic>>[])
        if (file['id'] case final Object id)
          NoteFile(
            id: '$id',
            name: '${file['name'] ?? id}',
            size: (file['size'] as num?)?.toInt(),
            contentType: file['content_type'] as String?,
          ),
    ];
    final listed = <String>{for (final file in files) file.id};
    return NoteDetail(
      summary: _summarize(note, access),
      ops: quillOpsFromMarkdown(markdown),
      pageId: page,
      markdown: markdown,
      pages: <NotePageDto>[
        if (note.isMultiPage)
          for (final entry in notePageEntries(note.data.pages, note.title))
            NotePageDto(
              id: entry.id,
              title: entry.title,
              path: entry.path,
              depth: entry.depth,
            ),
      ],
      files: <NoteFile>[
        ...files,
        // Open WebUI 0.12.5 keeps attachments as links in the content, and
        // the mobile editor lists those beside the file list.
        for (final link in noteFileLinksInMarkdown(markdown))
          if (listed.add(link.id)) NoteFile(id: link.id, name: link.name),
      ],
    );
  }

  /// The page of [note] shown for [pageId]: that page when the note has
  /// it, else the main page.
  static String _pageOf(Note note, String? pageId) {
    if (pageId == null || pageId == kNoteMainPageId) return kNoteMainPageId;
    final has =
        note.isMultiPage && note.data.pages.any((page) => page.id == pageId);
    return has ? pageId : kNoteMainPageId;
  }

  /// The stored markdown of page [pageId] of [note]; a note in the older
  /// shape, or with one page, has its content (as the phone's editor reads
  /// it).
  static String _pageMarkdown(Note note, String pageId) {
    if (note.isMultiPage) {
      for (final page in note.data.pages) {
        if (page.id == pageId) return page.content.md;
      }
    }
    return note.markdownContent;
  }

  /// Attaches an uploaded file to a note, written with its outbox
  /// operation as mobile attaches a recording, so it survives going
  /// offline. The attachment is Open WebUI's own file descriptor, which
  /// the web client shows too.
  ///
  /// As the core attaches a recording: a note with pages, or any note on a
  /// server that has them (Open WebUI 0.12.5 and later), gets a link to the
  /// file in its main page's content, which is where such a server looks;
  /// an older one gets the file in the note's file list.
  Future<NoteDetail> attach(NoteAttach request) =>
      _changeData(request.noteId, pageId: request.pageId, (data, pagesServer) {
        final attachment = <String, dynamic>{
          'type': 'file',
          'file': '',
          'id': request.file.id,
          'url': request.file.id,
          'name': request.file.name,
          'collection_name': '',
          'status': 'uploaded',
          'size': ?request.file.size,
          'content_type': ?request.file.contentType,
          'error': '',
          // Mobile's replay key, so a retried attach is not doubled.
          'itemId': request.file.id,
        };
        if (noteDataHasPages(data) || pagesServer) {
          // Null when the link is there already.
          return noteDataWithFileLink(
            data,
            attachment,
            pageId: notePageIdIn(data, request.pageId),
          );
        }
        final files = _filesIn(data);
        if (files.any((file) => '${file['id']}' == request.file.id)) {
          return null;
        }
        return <String, dynamic>{
          ...data,
          'files': <Map<String, dynamic>>[...files, attachment],
        };
      });

  /// Takes a file off a note, from its file list and from links to it in
  /// the main page. The file stays on the server.
  Future<NoteDetail> detach(NoteDetach request) =>
      _changeData(request.noteId, pageId: request.pageId, (data, _) {
        final page = notePageIdIn(data, request.pageId);
        final patch = noteDataWithoutFile(data, request.fileId, pageId: page);
        if (patch.isEmpty) return null;
        return applyNoteContentEdit(data, patch, pageId: page);
      });

  static List<Map<String, dynamic>> _filesIn(Map<String, dynamic> data) =>
      <Map<String, dynamic>>[
        if (data['files'] case final List<Object?> list)
          for (final file in list)
            if (file is Map) Map<String, dynamic>.from(file),
      ];

  /// Rewrites a note's stored data under its lock and queues the change.
  /// [change] returns the new data, or null for nothing to do; it is told
  /// whether the server keeps notes in pages.
  Future<NoteDetail> _changeData(
    String noteId,
    Map<String, dynamic>? Function(Map<String, dynamic> data, bool pagesServer)
    change, {
    String? pageId,
  }) async {
    await readSettled(_container, notesListProvider.future);
    // Whether the server has note pages comes from its config, which
    // nothing else in the daemon may have read yet.
    try {
      await readSettled(_container, backendConfigProvider.future);
    } on Object {
      // Unknown: treated as an older server, as the core treats it.
    }
    final pagesServer = _container.read(notePagesServerProvider) == true;
    final db = _container.read(appDatabaseProvider);
    if (db == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'attachments need the account database',
      );
    }
    final id = await db.notesDao.resolveNoteRemapTarget(noteId);
    await _container.read(noteLocksProvider).runExclusive(id, () async {
      final row = await db.notesDao.getNote(id);
      if (row == null || row.deleted) {
        throw RpcError(
          code: ConduitErrorCodes.notFound,
          debugMessage: 'no note $noteId',
        );
      }
      final changed = change(decodeNoteData(row.data), pagesServer);
      if (changed == null) return;
      await db.notesDao.updateNoteWithOutbox(
        id,
        data: Value(jsonEncode(changed)),
        localUpdatedAtNs: DateTime.now().microsecondsSinceEpoch * 1000,
        enqueue: true,
      );
    });
    // Pushed now; a failure leaves the operation queued for the next try.
    unawaited(
      _container
          .read(syncEngineProvider.notifier)
          .drainNow()
          .catchError((Object _) {}),
    );
    _container.invalidate(noteByIdProvider(id));
    final row = await db.notesDao.getNote(id);
    return _detail(
      Note.fromJson(noteRowToServer(row!)),
      await _access(),
      pageId: pageId,
    );
  }

  /// A note the server no longer has: gone, not an error.
  static bool _notFound(Object error) => switch (error) {
    ApiError(type: ApiErrorType.notFound) => true,
    DioException(error: ApiError(type: ApiErrorType.notFound)) => true,
    DioException(response: Response(statusCode: 404)) => true,
    _ => false,
  };

  Future<NoteDetail> save(NoteSave request) async {
    // The account the save was asked under, before any wait, whether or not
    // the editor names one: the note is written (or made) under it or not
    // at all.
    final account = AccountScope.capture(_container);
    final scope = account.preferenceAccount;
    // The editor's own account, when it says: another one active (a switch
    // this side has made and the window not yet heard of) takes nothing.
    _requireExpected(request.accountId, request.id);
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
    final access = await _access();
    final id = request.id;
    _requireExpected(request.accountId, id);
    if (id == null) {
      // Save as My Own Note, begun under another account than the one
      // active now: the draft is not made into this account's note.
      account.require('a new note was made');
    } else {
      // Begun under another account than the one active now (even when
      // that account has since read the same note): written by no path.
      account.require('note $id was saved');
      // A note opened under another account is written by no path (a
      // rename, the core's updater, the text): its draft stays with the
      // editor, never in this account's notes.
      _requireOpenedHere(id);
    }
    if (id == null) {
      final created = await _container
          .read(noteCreatorProvider.notifier)
          .createNote(title: title, markdownContent: markdown ?? '');
      if (created == null) throw _saveFailed(creating: true);
      return _detail(created, access, scope: scope);
    }
    final db = _container.read(appDatabaseProvider);
    if (markdown == null || db == null) {
      // A rename, or no database (reviewer mode): the core's updater.
      final saved = await _container
          .read(noteUpdaterProvider.notifier)
          .updateNote(id, title: title, markdownContent: markdown);
      _container.invalidate(noteByIdProvider(id));
      if (saved == null) throw _saveFailed(creating: false);
      return _detail(saved, access, pageId: request.pageId, scope: scope);
    }
    // A note deleted meanwhile -- by another device (a pull removed its
    // row) or behind this editor (its row is a tombstone) -- has nowhere
    // to save to: its text is kept as a new note.
    final resolved = await db.notesDao.resolveNoteRemapTarget(id);
    final existing = await db.notesDao.getNote(resolved);
    account.require('note $id was saved');
    if (existing == null || existing.deleted) {
      return _recover(
        id,
        title: title,
        markdown: markdown,
        access: access,
        previous: existing == null
            ? null
            : Note.fromJson(noteRowToServer(existing)),
      );
    }
    final pageId = request.pageId ?? kNoteMainPageId;
    final base = request.baseOps == null
        ? null
        : markdownFromQuillOps(request.baseOps!);
    final Note? saved;
    try {
      saved = await persistNoteUpdate(
        _container,
        noteId: id,
        writeId: _seen[id]?.id,
        api: _container.read(apiServiceProvider),
        db: db,
        title: title,
        data: noteContentData(markdown),
        // Read inside the note lock: a file link the stored page gained
        // since the editor loaded it is kept, and one the user took out
        // stays out.
        dataFrom: base == null
            ? null
            : (existing) => noteContentData(
                mergeNoteFileLinks(
                  base: base,
                  stored: notePageMarkdown(existing, pageId),
                  mine: markdown,
                ),
              ),
        pageId: pageId,
      );
    } on NoteWriteDeniedException {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        args: const <String, String>{'reason': 'readOnly'},
        debugMessage: 'the account may not edit note $id',
      );
    } on NotePageMissingException {
      throw _pageMissing(id, pageId);
    } on NotePageRequiredException {
      throw _pageMissing(id, pageId);
    }
    if (saved != null) {
      _container.invalidate(noteByIdProvider(id));
      return _detail(saved, access, pageId: pageId, scope: scope);
    }
    // Nothing was written. A note deleted while it was being written keeps
    // the text as a new note, as the phone's editor recovers it; anything
    // else is a failed save the editor retries.
    final row = await db.notesDao.getNote(resolved);
    if (row != null && !row.deleted) throw _saveFailed(creating: false);
    return _recover(id, title: title, markdown: markdown, access: access);
  }

  /// Keeps the draft of [id], which the server deleted, as a new note.
  Future<NoteDetail> _recover(
    String id, {
    required String title,
    required String markdown,
    required _Access access,
    Note? previous,
  }) async {
    // Its row is missing because another account is active now (each has
    // its own database): the draft stays out of that account's notes.
    _requireOpenedHere(id);
    final db = _container.read(appDatabaseProvider)!;
    previous ??=
        _seen[id] ?? Note(id: id, title: title, createdAt: 0, updatedAt: 0);
    final recovered = await createNoteFromDeletedDraft(
      _container,
      db,
      previous: previous,
      userId: access.accountId,
      title: title,
      markdown: markdown,
    );
    if (recovered == null) throw _saveFailed(creating: true);
    _container.invalidate(noteByIdProvider(id));
    _container.invalidate(noteByIdProvider(recovered.id));
    // Recordings still waiting move with the text.
    final recorder = _recorders.remove(id);
    if (recorder != null) {
      _recorders[recovered.id] = recorder;
      recorder.note = recovered;
      // Its news is the recovered note's from now on.
      recorder.noteId = recovered.id;
      unawaited(recorder.controller.rebindTo(previous, recovered));
    }
    return _detail(recovered, access).copyWith(recoveredFrom: id);
  }

  /// Refuses work for note [id] when it was handed out under another
  /// account than the one active now: a draft or recording of one account
  /// never goes into the next one's notes, storage or server. (A note this
  /// daemon has not handed out -- it restarted under an open editor -- is
  /// taken as the active account's, as before.)
  void _requireOpenedHere(String id) {
    if (!_seenUnder.containsKey(id)) return;
    if (_seenUnder[id] == currentPreferenceAccountId()) return;
    throw RpcError(
      code: ConduitErrorCodes.sessionExpired,
      args: const <String, String>{'reason': 'account'},
      debugMessage: 'note $id was opened under another account',
    );
  }

  /// The account a recording request for note [id] comes under, captured
  /// before anything is awaited: refused at once when the note was handed
  /// out under another one.
  AccountScope _recordingAccount(String id) {
    _requireOpenedHere(id);
    return AccountScope.capture(_container);
  }

  /// Refuses a recording request for note [id] begun under [account] once
  /// another account is active -- also for a note this daemon never handed
  /// out (it restarted under an open editor) -- or once the note was handed
  /// out under another account meanwhile.
  void _requireRecordingStill(String id, AccountScope account) {
    account.require('a request for note $id answered');
    _requireOpenedHere(id);
  }

  /// Refuses a save the editor made for account [expected] while another
  /// account is active (nothing is checked when the editor names none).
  void _requireExpected(String? expected, String? id) {
    if (expected == null || expected == currentPreferenceAccountId()) return;
    throw RpcError(
      code: ConduitErrorCodes.sessionExpired,
      args: const <String, String>{'reason': 'account'},
      debugMessage: 'note ${id ?? '(new)'} is for another account',
    );
  }

  static RpcError _saveFailed({required bool creating}) => RpcError(
    code: ConduitErrorCodes.serverError,
    debugMessage: creating
        ? 'the note could not be created'
        : 'the note could not be saved',
  );

  static RpcError _pageMissing(String id, String pageId) => RpcError(
    code: ConduitErrorCodes.notFound,
    args: const <String, String>{'reason': 'page'},
    debugMessage: 'note $id has no page $pageId',
  );

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
    return _summarize(updated, await _access());
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

  // Recordings.

  /// [noteId]'s recordings not attached yet; uploads the waiting ones when
  /// the server can be reached.
  Future<NoteRecordings> recordings(String noteId) async {
    // A note opened under another account: its recordings are that
    // account's, listed to no other (checked again after each read).
    final account = _recordingAccount(noteId);
    final recorder = await _recorderFor(noteId);
    _requireRecordingStill(noteId, account);
    await recorder.controller.loadPending();
    _requireRecordingStill(noteId, account);
    return _recordingsOf(noteId, recorder);
  }

  /// Keeps the audio file at [request.path] for the note (the core moves it
  /// into the account's storage before anything else), then uploads and
  /// attaches it.
  Future<NoteRecordings> addRecording(NoteRecordingAdd request) async {
    final account = _recordingAccount(request.noteId);
    final recorder = await _recorderFor(request.noteId);
    // Checked again after the reads: a switch meanwhile keeps the audio out
    // of the next account's storage.
    _requireRecordingStill(request.noteId, account);
    final file = File(request.path);
    if (!file.existsSync()) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'no recording at ${request.path}',
      );
    }
    final staged = await recorder.controller.stage(
      file,
      pageId: request.pageId,
    );
    // Another account may have opened and listed this note id meanwhile:
    // its list is not this request's answer.
    _requireRecordingStill(request.noteId, account);
    if (!staged) {
      throw const RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the recording could not be kept',
      );
    }
    return _recordingsOf(request.noteId, recorder);
  }

  Future<NoteRecordings> retryRecording(NoteRecordingRef request) async {
    final account = _recordingAccount(request.noteId);
    final recorder = await _recorderFor(request.noteId);
    _requireRecordingStill(request.noteId, account);
    unawaited(
      recorder.controller.retry(ids: <String>[request.id], showFeedback: true),
    );
    return _recordingsOf(request.noteId, recorder);
  }

  Future<NoteRecordings> removeRecording(NoteRecordingRef request) async {
    final account = _recordingAccount(request.noteId);
    final recorder = await _recorderFor(request.noteId);
    _requireRecordingStill(request.noteId, account);
    await recorder.controller.removePending(request.id);
    _requireRecordingStill(request.noteId, account);
    return _recordingsOf(request.noteId, recorder);
  }

  /// One of [noteId]'s recordings still waiting to go to the server, as
  /// it was recorded, for `GET /recordings/{id}?noteId=` (the window plays
  /// it, as the phone plays a recording before it is uploaded).
  Future<({Uint8List bytes, String contentType})> waitingRecording(
    String noteId,
    String id,
  ) async {
    // Played only under the account the note was opened under, and only
    // while it is still the one active (checked again after each wait).
    final account = _recordingAccount(noteId);
    final recorder = await _recorderFor(noteId);
    _requireRecordingStill(noteId, account);
    final item = recorder.controller.pending
        .where((p) => p.id == id)
        .firstOrNull;
    final file = item == null ? null : File(item.localPath);
    if (file == null || !await file.exists()) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no waiting recording $id',
      );
    }
    final bytes = await file.readAsBytes();
    _requireRecordingStill(noteId, account);
    return (bytes: bytes, contentType: audioTypeOf(item!.fileName));
  }

  /// A recording's type by its name, as players take it.
  static String audioTypeOf(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'm4a' || 'mp4' => 'audio/mp4',
      'wav' => 'audio/wav',
      'mp3' => 'audio/mpeg',
      'aac' => 'audio/aac',
      'caf' => 'audio/x-caf',
      'flac' => 'audio/flac',
      'ogg' || 'oga' => 'audio/ogg',
      'webm' => 'audio/webm',
      _ => 'application/octet-stream',
    };
  }

  Future<_NoteRecorder> _recorderFor(String noteId) async {
    final store = _audioStore;
    if (store == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'recordings need the daemon\'s storage',
      );
    }
    _requireOpen();
    final note = await _storedNote(noteId);
    // Shutdown may have begun while the note was read: no recorder is made
    // or handed out that it would not wait for.
    _requireOpen();
    final existing = _recorders[noteId];
    if (existing != null) {
      existing.note = note ?? existing.note;
      return existing;
    }
    late final _NoteRecorder recorder;
    final controller = NoteAttachmentsController(
      container: _container,
      store: store,
      noteId: noteId,
      currentNote: () => recorder.note,
      resolvedTitle: () => recorder.note?.title ?? '',
      onNoteUpdated: (note) {
        recorder.note = note;
        _seen[note.id] = note;
        _container.invalidate(noteByIdProvider(note.id));
        _changed(recorder.noteId);
      },
      // Only a change of the list is news: the controller also notifies
      // after every scan, and an editor asks for the list again on
      // `notes.changed` -- announcing each scan fed back without end.
      // By the id the recorder is kept under now: a recovered note's
      // recorder moved to the new note's id.
      onChanged: () => _recordingsChanged(recorder.noteId),
      onNotice: (notice) => recorder.lastNotice = notice,
    );
    recorder = _NoteRecorder(controller, noteId)..note = note;
    _recorders[noteId] = recorder;
    controller.start();
    return recorder;
  }

  /// The note as stored on this computer, or as last handed to an editor.
  Future<Note?> _storedNote(String noteId) async {
    final db = _container.read(appDatabaseProvider);
    if (db != null) {
      final id = await db.notesDao.resolveNoteRemapTarget(noteId);
      final stored = await readLocalNote(db, id);
      if (stored != null) return stored;
    }
    return _seen[noteId];
  }

  static NoteRecordings _recordingsOf(String noteId, _NoteRecorder recorder) {
    final controller = recorder.controller;
    return NoteRecordings(
      noteId: noteId,
      recordings: <NoteRecordingDto>[
        for (final item in controller.pending)
          NoteRecordingDto(
            id: item.id,
            name: item.fileName,
            size: item.fileSize,
            createdAtMs: item.createdAt.millisecondsSinceEpoch,
            pageId: item.pageId,
            state:
                controller.isInFlight(item.id) ||
                    item.status == NoteAudioUploadStatus.uploading ||
                    item.status == NoteAudioUploadStatus.attaching
                ? NoteRecordingState.uploading
                : item.status == NoteAudioUploadStatus.failed
                ? NoteRecordingState.failed
                : NoteRecordingState.waiting,
          ),
      ],
    );
  }

  void _recordingsChanged(String noteId) {
    final recorder = _recorders[noteId];
    if (recorder == null) return;
    final now = _recordingsOf(noteId, recorder);
    if (now == recorder.announced) return;
    recorder.announced = now;
    _changed(noteId);
  }

  void _changed(String noteId) => _events?.emit(
    ConduitEventSpecs.notesChanged,
    NotesChanged(noteId: noteId),
  );

  /// Stops every recordings controller (the daemon is stopping).
  void dispose() {
    for (final recorder in _recorders.values) {
      recorder.controller.dispose();
    }
    _recorders.clear();
  }

  /// Set once [close] begins: from then on no recorder is made or handed
  /// out, so the recorders it waits for are all there are.
  bool _closing = false;

  void _requireOpen() {
    if (_closing) {
      throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the daemon is stopping',
      );
    }
  }

  /// [dispose], and waits until no recorder writes any more: what a
  /// recording's upload was writing is written, and nothing comes after.
  /// Recorders are admitted no more first, so none starts after the
  /// snapshot below. Every call waits for that one drain: a later caller
  /// finds no recorders left to wait for, yet theirs may still be writing.
  Future<void> close() => _closed ??= _drain();

  Future<void>? _closed;

  Future<void> _drain() async {
    _closing = true;
    final controllers = [
      for (final recorder in _recorders.values) recorder.controller,
    ];
    _recorders.clear();
    await Future.wait([
      for (final controller in controllers) controller.close(),
    ]);
  }

  /// `notes.changed` whenever the list does: an edit here, a sync, another
  /// window.
  void _announceChanges(EventBus events) {
    void changed() =>
        events.emit(ConduitEventSpecs.notesChanged, const NotesChanged());
    _container.listen<AsyncValue<List<Note>>>(notesListProvider, (_, next) {
      if (next.hasValue) changed();
    });
    // And when the server's sharing permission arrives, which each
    // summary's Share Access… depends on: straight after signing in the
    // list can come first. The phone's list watches it and redraws; here
    // the app lists again. (The list itself waits for the account.)
    _container.listen<AsyncValue<WorkspaceCapabilities>>(
      workspaceCapabilitiesProvider,
      (previous, next) {
        final was = previous?.asData?.value.notes.section.share;
        final now = next.asData?.value.notes.section.share;
        if (now != null && now != was) changed();
      },
    );
  }

  static NoteSummary _summarize(Note note, _Access access) {
    final writeAccess = noteWriteAccess(note, accountId: access.accountId);
    final canEdit = writeAccess == NoteWriteAccess.allowed;
    return NoteSummary(
      id: note.id,
      title: note.title,
      // Open WebUI stamps notes in nanoseconds.
      updatedAtMs: note.updatedAt ~/ 1000000,
      pinned: note.isPinned,
      preview: _preview(note.listPreviewMarkdown),
      section: _section(note),
      canEdit: canEdit,
      accessUnverified: writeAccess == NoteWriteAccess.unknown,
      canShare: noteShareable(
        note,
        accountId: access.accountId,
        notesSharingAllowed: access.sharing,
      ),
      owner: noteSharedOwner(note, accountId: access.accountId)?.name?.trim(),
    );
  }

  /// The note's time group, on the core's calendar days.
  static NoteSection _section(Note note) => switch (getTimeRangeForTimestamp(
    DateTime.fromMicrosecondsSinceEpoch(note.updatedAt ~/ 1000),
  )) {
    TimeRange.today => NoteSection.today,
    TimeRange.yesterday => NoteSection.yesterday,
    TimeRange.previousSevenDays => NoteSection.previous7Days,
    TimeRange.previousThirtyDays => NoteSection.previous30Days,
    TimeRange.older => NoteSection.older,
  };

  static String _preview(String markdown) {
    final text = markdown.trim();
    return text.length <= 200 ? text : '${text.substring(0, 200)}…';
  }
}

typedef _Access = ({String? accountId, bool sharing});

/// A note's recordings controller and the note it works on.
final class _NoteRecorder {
  _NoteRecorder(this.controller, this.noteId);

  final NoteAttachmentsController controller;

  /// The note it is kept under in `_recorders`: the recovered note's id
  /// once a deleted note's draft was kept as a new one.
  String noteId;
  Note? note;
  NoteAudioNotice? lastNotice;

  /// The list as last announced with `notes.changed`.
  NoteRecordings? announced;
}
