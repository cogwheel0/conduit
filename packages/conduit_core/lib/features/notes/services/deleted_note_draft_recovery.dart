import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart';
import 'package:conduit_core/features/notes/services/note_attachments_controller.dart';
import 'package:conduit_core/features/notes/utils/note_persistence.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// The `data` patch a note's markdown is saved as. Open WebUI prefers HTML
/// when it is non-empty, and Parchment's checklist HTML is not TipTap
/// compatible, so it is left empty for Open WebUI to derive its editor
/// document from the canonical markdown.
Map<String, dynamic> noteContentData(String markdown) => <String, dynamic>{
  'content': <String, dynamic>{'json': null, 'html': '', 'md': markdown},
};

/// The session a recovery was requested in, captured before the awaits that
/// lead to it: the API service, database, auth epoch and user id.
class NoteRecoverySession {
  NoteRecoverySession({
    required this.api,
    required this.db,
    required this.authEpoch,
    required this.userId,
  });

  factory NoteRecoverySession.capture(ProviderContainer container) =>
      NoteRecoverySession(
        api: container.read(apiServiceProvider),
        db: container.read(appDatabaseProvider),
        authEpoch: container.read(openWebUiAuthSessionEpochProvider),
        userId: container.read(currentUserProvider2)?.id,
      );

  final Object? api;
  final AppDatabase? db;
  final Object authEpoch;
  final String? userId;
}

/// The text the editor holds.
typedef NoteDraftSnapshot = ({String title, String markdown});

/// Saves the edits of a note the server deleted as a new local note.
///
/// A pull that finds the open note gone removes its local row, so an edit not
/// yet saved has nowhere to go: the update would fail. The draft (its title
/// and markdown over the deleted note's other data) is created as a `local:`
/// note through the durable outbox instead, the recordings still waiting to
/// upload are moved to it ([NoteAttachmentsController.rebindTo]), and the
/// editor carries on with the new note. A failed creation keeps the draft and
/// tries again two seconds after, and on the next save.
class DeletedNoteDraftRecovery {
  DeletedNoteDraftRecovery({
    required ProviderContainer container,
    required String noteId,
    required NoteAttachmentsController attachments,
    required Note? Function() currentNote,
    required NoteDraftSnapshot Function() readDraft,
    required String Function() untitledTitle,
    required bool Function() isOpen,
    required bool Function() hasUnsavedChanges,
    required void Function() cancelPendingSave,
    required void Function(Duration delay, void Function() action)
    scheduleSaveAfter,
    required void Function() saveSoon,
    required void Function({
      required Note note,
      required String savedMarkdown,
      required bool changedDuringRecovery,
    })
    onRecovered,
    required void Function() onFailure,
  }) : _container = container,
       _noteId = noteId,
       _attachments = attachments,
       _currentNote = currentNote,
       _readDraft = readDraft,
       _untitledTitle = untitledTitle,
       _isOpen = isOpen,
       _hasUnsavedChanges = hasUnsavedChanges,
       _cancelPendingSave = cancelPendingSave,
       _scheduleSaveAfter = scheduleSaveAfter,
       _saveSoon = saveSoon,
       _onRecovered = onRecovered,
       _onFailure = onFailure;

  final ProviderContainer _container;
  final String _noteId;
  final NoteAttachmentsController _attachments;
  final Note? Function() _currentNote;
  final NoteDraftSnapshot Function() _readDraft;
  final String Function() _untitledTitle;
  final bool Function() _isOpen;
  final bool Function() _hasUnsavedChanges;
  final void Function() _cancelPendingSave;
  final void Function(Duration delay, void Function() action)
  _scheduleSaveAfter;
  final void Function() _saveSoon;
  final void Function({
    required Note note,
    required String savedMarkdown,
    required bool changedDuringRecovery,
  })
  _onRecovered;
  final void Function() _onFailure;

  void Function()? _retry;
  bool _recovering = false;
  bool _queued = false;
  ProviderSubscription<Object>? _authEpochSubscription;

  /// The action the editor's debounced save should run in place of an
  /// ordinary save while a recovery is owed, or null.
  void Function()? get pendingRetry => _retry;

  /// Forgets a recovery owed for a session the user has left. Call from
  /// `initState`.
  void start() {
    _authEpochSubscription = _container.listen<Object>(
      openWebUiAuthSessionEpochProvider,
      (previous, next) {
        _retry = null;
        _queued = false;
      },
    );
  }

  void dispose() {
    _authEpochSubscription?.close();
    _authEpochSubscription = null;
  }

  /// Creates a note from the draft. [session] is what the caller captured
  /// before the sync that found the note gone. [showFailure] is false for the
  /// automatic retries, so a note that stays unsavable does not nag.
  Future<void> recover(
    NoteRecoverySession session, {
    bool showFailure = true,
  }) async {
    if (_recovering) {
      _queued = true;
      return;
    }
    _recovering = true;
    try {
      await _recoverOnce(session, showFailure: showFailure);
    } finally {
      _recovering = false;
      if (_queued) {
        _queued = false;
        if (_isOpen() && _hasUnsavedChanges() && _retry != null) {
          _saveSoon();
        }
      }
    }
  }

  bool _isCurrent(NoteRecoverySession session) =>
      _isOpen() &&
      isCurrentNoteEditorSession(
        _container,
        api: session.api,
        db: session.db,
        authEpoch: session.authEpoch,
      );

  Future<void> _recoverOnce(
    NoteRecoverySession session, {
    required bool showFailure,
  }) async {
    final Note? previous = _currentNote();
    final AppDatabase? db = session.db;
    if (previous == null || db == null || !_isCurrent(session)) return;

    _retry = () {
      if (!_isOpen()) return;
      unawaited(recover(session, showFailure: false));
    };

    _cancelPendingSave();
    final NoteDraftSnapshot draft = _readDraft();
    final Map<String, dynamic> draftData = <String, dynamic>{
      ...previous.data.toJson(),
      ...noteContentData(draft.markdown),
    };
    Note? recovered;
    try {
      recovered = await durableCreateNote(
        _container,
        db,
        userId: session.userId,
        title: draft.title.trim().isEmpty
            ? _untitledTitle()
            : draft.title.trim(),
        data: draftData,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'deleted-note-draft-recovery-failed',
        scope: 'notes/recovery',
        error: error,
        stackTrace: stackTrace,
        data: {'noteId': previous.id},
      );
      if (_isCurrent(session)) {
        _scheduleRetry(session);
        if (showFailure) _onFailure();
      }
      return;
    }
    if (!_isCurrent(session)) return;
    if (recovered == null) {
      _scheduleRetry(session);
      if (showFailure) _onFailure();
      return;
    }

    // The draft is durable at this point. Publish the replacement before any
    // recording migration I/O so a filesystem failure cannot retry creation
    // and produce a duplicate recovered note.
    final NoteDraftSnapshot now = _readDraft();
    final bool changedDuringRecovery =
        now.title != draft.title || now.markdown != draft.markdown;
    _retry = null;
    _container.invalidate(noteByIdProvider(_noteId));
    if (previous.id != _noteId) {
      _container.invalidate(noteByIdProvider(previous.id));
    }
    _container.invalidate(noteByIdProvider(recovered.id));
    _onRecovered(
      note: recovered,
      savedMarkdown: draft.markdown,
      changedDuringRecovery: changedDuringRecovery,
    );
    if (changedDuringRecovery) _saveSoon();

    await _attachments.rebindTo(previous, recovered);
  }

  void _scheduleRetry(NoteRecoverySession session) {
    if (!_isOpen() || !_hasUnsavedChanges() || !_isCurrent(session)) return;
    _cancelPendingSave();
    _scheduleSaveAfter(const Duration(seconds: 2), () {
      if (!_isOpen() || !_hasUnsavedChanges() || !_isCurrent(session)) return;
      _retry?.call();
    });
  }
}
