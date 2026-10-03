import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';

import 'package:conduit_core/database/app_database.dart';

import 'package:conduit_core/database/database_provider.dart';

import 'package:conduit_core/models/note.dart';

import 'package:conduit_core/providers/app_providers.dart';

import '../../../core/services/ios_native_dropdown_bridge.dart';

import 'package:conduit_core/sync/sync_engine.dart';

import 'package:conduit_core/features/notes/services/deleted_note_draft_recovery.dart';
import 'package:conduit_core/features/notes/services/note_ai_actions.dart';
import 'package:conduit_core/features/notes/services/note_attachments_controller.dart';
import 'package:conduit_core/features/notes/services/note_dictation.dart';
import 'package:conduit_core/features/notes/utils/note_persistence.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/horizontal_gesture_ownership.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/themed_sheets.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import '../../chat/services/voice_input_service.dart';
import '../providers/notes_providers.dart';
import '../services/note_audio_upload_service.dart';
import '../utils/note_document_codec.dart';
import '../widgets/audio_player_dialog.dart';
import '../widgets/audio_recording_overlay.dart';
import '../widgets/note_file_attachment.dart';
import '../widgets/note_floating_actions.dart';

/// Builds the rich-note editor theme from Conduit's semantic color tokens.
///
/// Fleather's fallback block styles derive their colors from a separate
/// [DefaultTextStyle]. Every block type must therefore be mapped explicitly so
/// headings and lists remain readable in both brightness modes.
FleatherThemeData buildNoteEditorFleatherTheme(BuildContext context) {
  final theme = context.conduitTheme;
  final fallback = FleatherThemeData.fallback(context);
  final base = AppTypography.bodyLargeStyle.copyWith(
    color: theme.textPrimary,
    height: 1.8,
  );

  TextStyle blockStyle(TextStyle source, {Color? color}) {
    return base
        .merge(source)
        .copyWith(
          color: color ?? theme.textPrimary,
          fontFamily: AppTypography.fontFamily,
        );
  }

  TextBlockTheme themedBlock(
    TextBlockTheme source, {
    TextStyle? style,
    BoxDecoration? decoration,
  }) {
    return TextBlockTheme(
      style: style ?? blockStyle(source.style),
      spacing: source.spacing,
      lineSpacing: source.lineSpacing,
      decoration: decoration ?? source.decoration,
    );
  }

  TextStyle inlineCodeStyle(TextStyle? source) {
    return (source ?? fallback.inlineCode.style).copyWith(
      color: theme.codeText,
      fontFamily: AppTypography.monospaceFontFamily,
    );
  }

  return fallback.copyWith(
    paragraph: TextBlockTheme(
      style: base,
      spacing: const VerticalSpacing(top: 0, bottom: 6),
    ),
    heading1: themedBlock(fallback.heading1),
    heading2: themedBlock(fallback.heading2),
    heading3: themedBlock(fallback.heading3),
    heading4: themedBlock(fallback.heading4),
    heading5: themedBlock(fallback.heading5),
    heading6: themedBlock(fallback.heading6),
    lists: themedBlock(fallback.lists, style: base),
    quote: themedBlock(
      fallback.quote,
      style: blockStyle(fallback.quote.style, color: theme.textSecondary),
      decoration: BoxDecoration(
        border: BorderDirectional(
          start: BorderSide(width: 4, color: theme.dividerColor),
        ),
      ),
    ),
    code: themedBlock(
      fallback.code,
      style: fallback.code.style.copyWith(
        color: theme.codeText,
        fontFamily: AppTypography.monospaceFontFamily,
      ),
      decoration: BoxDecoration(
        color: theme.codeBackground,
        border: Border.all(color: theme.codeBorder),
        borderRadius:
            fallback.code.decoration?.borderRadius ?? BorderRadius.circular(2),
      ),
    ),
    inlineCode: InlineCodeThemeData(
      style: inlineCodeStyle(fallback.inlineCode.style),
      heading1: inlineCodeStyle(fallback.inlineCode.heading1),
      heading2: inlineCodeStyle(fallback.inlineCode.heading2),
      heading3: inlineCodeStyle(fallback.inlineCode.heading3),
      backgroundColor: theme.codeBackground,
      radius: fallback.inlineCode.radius,
    ),
    horizontalRuleThemeData: HorizontalRuleThemeData(
      height: fallback.horizontalRule.height,
      thickness: fallback.horizontalRule.thickness,
      color: theme.dividerColor,
    ),
    bold: const TextStyle(fontWeight: FontWeight.bold),
    italic: const TextStyle(fontStyle: FontStyle.italic),
    link: TextStyle(
      color: theme.buttonPrimary,
      decoration: TextDecoration.underline,
    ),
  );
}

/// Page for editing a note with OpenWebUI-style layout.
class NoteEditorPage extends ConsumerStatefulWidget {
  final String noteId;

  const NoteEditorPage({super.key, required this.noteId});

  @override
  ConsumerState<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends ConsumerState<NoteEditorPage> {
  final TextEditingController _titleController = TextEditingController();
  FleatherController? _contentController;
  StreamSubscription<ParchmentChange>? _contentChangesSubscription;
  final FocusNode _titleFocusNode = FocusNode(debugLabel: 'note_title');
  final FocusNode _contentFocusNode = FocusNode(debugLabel: 'note_content');
  final ScrollController _scrollController = ScrollController();

  Timer? _saveDebounce;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _hasChanges = false;
  bool _isGeneratingTitle = false;
  bool _isEnhancing = false;
  bool _isRecording = false;
  Note? _note;

  late final ProviderContainer _container;
  late final NoteAttachmentsController _attachments;
  late final DeletedNoteDraftRecovery _recovery;

  // Voice input
  VoiceInputService? _voiceService;
  StreamSubscription<String>? _voiceSub;
  // The in-progress dictation run: each (cumulative) transcript update
  // replaces the previous one without disturbing the rest of the document.
  NoteDictationRun? _dictationRun;

  // Markdown snapshot of the last saved/loaded document, used to detect real
  // edits. Compared against the re-encoded current document so opening a note
  // never registers as a spurious change from non-semantic markdown
  // normalisation.
  String _savedMarkdown = '';

  static final _whitespacePattern = RegExp(r'\s+');
  int _cachedWordCount = 0;

  // Cached Fleather theme. Derived from the app theme via the inherited
  // context, so it is (re)computed in didChangeDependencies rather than on
  // every build — the editor and toolbar both consume it each frame.
  FleatherThemeData? _fleatherTheme;

  /// Plain text of the current document (empty when no note is loaded).
  String get _contentPlainText =>
      _contentController?.document.toPlainText().trimRight() ?? '';

  /// Markdown encoding of the current document.
  String get _contentMarkdown {
    final controller = _contentController;
    return controller == null ? '' : markdownFromDocument(controller.document);
  }

  void _updateWordCount() {
    final text = _contentPlainText.trim();
    _cachedWordCount = text.isEmpty ? 0 : text.split(_whitespacePattern).length;
  }

  int get _charCount => _contentPlainText.length;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _attachments = NoteAttachmentsController(
      container: _container,
      store: createNoteAudioUploadStore(),
      noteId: widget.noteId,
      currentNote: () => _note,
      resolvedTitle: _resolvedTitle,
      onNoteUpdated: (note) {
        if (mounted) setState(() => _note = note);
      },
      onChanged: () {
        if (mounted) setState(() {});
      },
      onNotice: _onAudioNotice,
    )..start();
    _recovery = DeletedNoteDraftRecovery(
      container: _container,
      noteId: widget.noteId,
      attachments: _attachments,
      currentNote: () => _note,
      readDraft: () =>
          (title: _titleController.text, markdown: _contentMarkdown),
      untitledTitle: () => AppLocalizations.of(context)!.untitled,
      isOpen: () => mounted,
      hasUnsavedChanges: () => _hasChanges,
      cancelPendingSave: () => _saveDebounce?.cancel(),
      scheduleSaveAfter: (delay, action) {
        _saveDebounce?.cancel();
        _saveDebounce = Timer(delay, action);
      },
      saveSoon: _debounceSave,
      onRecovered:
          ({
            required note,
            required savedMarkdown,
            required changedDuringRecovery,
          }) {
            setState(() {
              _note = note;
              _savedMarkdown = savedMarkdown;
              _hasChanges = changedDuringRecovery;
            });
          },
      onFailure: () => _showError(AppLocalizations.of(context)!.errorMessage),
    )..start();
    _loadNote();
    _titleController.addListener(_onContentChanged);
    // The content controller is created once the note is loaded; its listener
    // is wired up in [_installContentDocument].
    // Rebuild when title focus changes to show/hide the generate title button
    _titleFocusNode.addListener(_onTitleFocusChanged);
    // Rebuild to show/hide the formatting toolbar as the editor gains/loses
    // focus.
    _contentFocusNode.addListener(_onContentFocusChanged);
  }

  void _onTitleFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onContentFocusChanged() {
    if (!mounted) return;
    // When the editor loses focus (e.g. the user taps away or starts
    // navigating elsewhere), flush any pending edit immediately instead of
    // waiting out the debounce, so a quick format-then-leave isn't dropped.
    if (!_contentFocusNode.hasFocus && _hasChanges) {
      _saveDebounce?.cancel();
      unawaited(_autoSave());
    }
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fleatherTheme = _buildFleatherTheme(context);
  }

  /// Replaces the content editor's controller with one backed by [document],
  /// disposing the previous controller. Used on initial load and whenever the
  /// whole document is swapped (e.g. AI enhancement).
  ///
  /// Does not touch [_savedMarkdown]: callers that load already-persisted
  /// content reset the baseline themselves, while callers that introduce new
  /// content (enhancement) leave it so the change is detected and auto-saved.
  void _installContentDocument(ParchmentDocument document) {
    final previous = _contentController;
    final controller = FleatherController(document: document);
    _contentChangesSubscription?.cancel();
    _contentChangesSubscription = document.changes.listen(
      (_) => _onContentChanged(),
    );
    _contentController = controller;
    previous?.dispose();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _voiceSub?.cancel();
    _recovery.dispose();
    _attachments.dispose();
    // The service is the app-wide provider instance shared with the chat
    // composer: never dispose it here, and only stop it when this editor's
    // own dictation run is still the active listener.
    if (_isRecording) _voiceService?.stopListening();
    _titleController.dispose();
    _contentChangesSubscription?.cancel();
    _contentController?.dispose();
    _titleFocusNode.removeListener(_onTitleFocusChanged);
    _titleFocusNode.dispose();
    _contentFocusNode.removeListener(_onContentFocusChanged);
    _contentFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool _isCurrentNoteSession({
    required Object? api,
    required Object? db,
    Object? authEpoch,
  }) => isCurrentNoteEditorSession(
    ref,
    api: api,
    db: db as AppDatabase?,
    authEpoch: authEpoch,
  );

  String _resolvedTitle() {
    final title = _titleController.text.trim();
    return title.isEmpty ? AppLocalizations.of(context)!.untitled : title;
  }

  void _onAudioNotice(NoteAudioNotice notice) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    switch (notice) {
      case NoteAudioNotice.recordingSaved:
        ConduitHaptics.mediumImpact();
        AdaptiveSnackBar.show(
          context,
          message: l10n.audioRecordingSaved,
          type: AdaptiveSnackBarType.success,
          duration: const Duration(seconds: 2),
        );
      case NoteAudioNotice.uploadFailed:
        _showError(l10n.failedToUploadAudio);
      case NoteAudioNotice.removed:
        ConduitHaptics.lightImpact();
        AdaptiveSnackBar.show(
          context,
          message: l10n.fileRemoved,
          type: AdaptiveSnackBarType.success,
          duration: const Duration(seconds: 2),
        );
      case NoteAudioNotice.error:
        _showError(l10n.errorMessage);
    }
  }

  Future<void> _loadNote() async {
    setState(() => _isLoading = true);

    try {
      final note = await _readNoteById(widget.noteId);

      if (mounted) {
        if (note == null) {
          setState(() => _isLoading = false);
          return;
        }
        setState(() {
          _note = note;
          _titleController.text = note.title;
          _installContentDocument(documentFromMarkdown(note.markdownContent));
          _savedMarkdown = _contentMarkdown;
          _updateWordCount();
          _isLoading = false;
          _hasChanges = false;
        });
        unawaited(_attachments.loadPending());
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showError(e.toString());
      }
    }
  }

  Future<Note?> _readNoteById(String noteId) {
    final provider = noteByIdProvider(noteId);
    final current = ref.read(provider);
    if (current.hasValue) {
      return Future<Note?>.value(current.value);
    }
    if (current.hasError) {
      return Future<Note?>.error(
        current.error ?? StateError('Failed to load note'),
      );
    }

    final completer = Completer<Note?>();
    ProviderSubscription<AsyncValue<Note?>>? subscription;

    void completeFromState(AsyncValue<Note?> state) {
      if (completer.isCompleted) return;
      if (state.hasValue) {
        completer.complete(state.value);
      } else if (state.hasError) {
        completer.completeError(
          state.error ?? StateError('Failed to load note'),
        );
      }
    }

    subscription = ref.listenManual<AsyncValue<Note?>>(
      provider,
      (_, next) => completeFromState(next),
      fireImmediately: true,
    );

    return completer.future.whenComplete(() => subscription?.close());
  }

  void _onContentChanged() {
    if (!mounted || _isLoading || _note == null) return;

    // Optimistically flag the note dirty so the unsaved indicator reacts
    // immediately. The authoritative comparison — which re-encodes the document
    // to markdown — is deferred to the debounced auto-save so we never run a
    // full delta->markdown traversal on every keystroke.
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
    _debounceSave();
    _updateWordCount();
  }

  void _debounceSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 800),
      _recovery.pendingRetry ?? _autoSave,
    );
  }

  /// Handles a back-navigation attempt. Reached only when [canPop] was false,
  /// i.e. there is a pending edit: flush it while still mounted (so the durable
  /// write doesn't race teardown), then pop programmatically.
  Future<void> _onEditorPopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    _saveDebounce?.cancel();
    await _autoSave();
    // Keep the editor open if persistence failed. In particular, a remotely
    // deleted note needs its recovery retry to remain mounted rather than
    // silently discarding the draft during navigation.
    if (mounted) {
      if (_hasChanges) {
        _recovery.pendingRetry?.call();
      } else if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(result);
      }
    }
  }

  Future<void> _autoSave() async {
    final note = _note;
    if (note == null) return;

    // Authoritative dirty check: compare the re-encoded markdown against the
    // snapshot taken on load/save so markdown normalisation on open never
    // registers as an edit, and a no-op edit never hits the server.
    final titleChanged = _titleController.text != note.title;
    final contentChanged = _contentMarkdown != _savedMarkdown;
    if (!titleChanged && !contentChanged) {
      if (mounted && _hasChanges) {
        setState(() => _hasChanges = false);
      }
      return;
    }
    await _saveNote(showFeedback: false);
  }

  /// Builds the note `data` PATCH for an update: `content` when
  /// [includeContent] is true, plus `files` when [files] is provided. It
  /// deliberately does NOT spread the (possibly stale) in-memory `_note.data`:
  /// `durableUpdateNote` merges this patch onto the CURRENT DB row, which
  /// preserves server-managed fields like `versions` (a pull may have added
  /// entries while the editor was open — spreading the editor's stale copy here
  /// would revert them on the next save).
  Map<String, dynamic> _composeUpdatedNoteData({
    List<Map<String, dynamic>>? files,
    bool includeContent = true,
  }) {
    final data = <String, dynamic>{};
    if (includeContent) {
      data.addAll(noteContentData(_contentMarkdown));
    }
    if (files != null) {
      data['files'] = files;
    }
    return data;
  }

  /// Persists a note title/data edit through the durable outbox path (when a
  /// Drift database is active) so an offline edit is never lost, falling back to
  /// the API-first path in reviewer mode / with no active server. Returns the
  /// stored note, or `null` if it could not be persisted.
  ///
  /// [api]/[db] are the session captured by the caller BEFORE its awaits; if the
  /// active account/database changed in the meantime (e.g. during an audio
  /// upload), this bails without persisting so the old editor's note is never
  /// written into a newly active account.
  Future<Note?> _persistNoteUpdate({
    required Object? api,
    required AppDatabase? db,
    required String title,
    required Map<String, dynamic> data,
    Object? authEpoch,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    return persistNoteUpdate(
      ref,
      noteId: widget.noteId,
      writeId: _note?.id,
      api: api,
      db: db,
      title: title,
      data: data,
      authEpoch: authEpoch,
      authSnapshot: authSnapshot,
      cancelToken: cancelToken,
      isStillOpen: () => mounted,
    );
  }

  Future<void> _saveNote({bool showFeedback = true}) async {
    if (_note == null) return;

    setState(() => _isSaving = true);

    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);
    if (api == null && db == null) {
      setState(() => _isSaving = false);
      return;
    }

    try {
      final title = _titleController.text.trim();

      // Preserve existing note data (versions, attached files) — only the
      // content changes here.
      final savedMarkdown = _contentMarkdown;
      final data = _composeUpdatedNoteData();

      final resolvedTitle = title.isEmpty
          ? AppLocalizations.of(context)!.untitled
          : title;
      final updatedNote = await _persistNoteUpdate(
        api: api,
        db: db,
        title: resolvedTitle,
        data: data,
      );

      if (mounted) {
        if (!_isCurrentNoteSession(api: api, db: db)) {
          setState(() => _isSaving = false);
          return;
        }

        if (updatedNote != null) {
          setState(() {
            _note = updatedNote;
            _savedMarkdown = savedMarkdown;
            _isSaving = false;
            _hasChanges = false;
          });

          if (showFeedback) {
            ConduitHaptics.lightImpact();
          }
        } else {
          setState(() => _isSaving = false);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        _showError(e.toString());
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: AdaptiveSnackBarType.error,
    );
  }

  Future<void> _deleteNote() async {
    final note = _note;
    if (note == null) return;

    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.deleteNoteTitle,
      message: l10n.deleteNoteMessage(
        note.title.isEmpty ? l10n.untitled : note.title,
      ),
      confirmText: l10n.delete,
      isDestructive: true,
    );

    if (confirmed && mounted) {
      ConduitHaptics.mediumImpact();
      final success = await ref
          .read(noteDeleterProvider.notifier)
          .deleteNote(note.id);
      if (success && mounted) {
        context.go('/chat');
      }
    }
  }

  Future<void> _togglePin() async {
    final note = _note;
    if (note == null) {
      return;
    }

    final updated = await ref
        .read(notePinTogglerProvider.notifier)
        .togglePin(note);
    if (updated == null || !mounted) {
      return;
    }

    setState(() => _note = updated);
    ConduitHaptics.selectionClick();
  }

  // AI title generation
  Future<void> _generateTitle() async {
    if (_note == null || _isGeneratingTitle) return;
    final l10n = AppLocalizations.of(context)!;

    setState(() => _isGeneratingTitle = true);
    ConduitHaptics.lightImpact();
    try {
      final result = await generateNoteTitle(_container, _contentMarkdown);
      if (!mounted) return;
      switch (result.outcome) {
        case NoteAiOutcome.done:
          _titleController.text = result.text!;
          ConduitHaptics.mediumImpact();
        case NoteAiOutcome.noContent:
          _showError(l10n.noContentToGenerateTitle);
        case NoteAiOutcome.noModel:
          _showError(l10n.noModelSelected);
        case NoteAiOutcome.failed:
          _showError(l10n.failedToGenerateTitle);
        case NoteAiOutcome.unavailable:
        case NoteAiOutcome.empty:
          break;
      }
    } finally {
      if (mounted) {
        setState(() => _isGeneratingTitle = false);
      }
    }
  }

  // AI content enhancement
  Future<void> _enhanceContent() async {
    if (_note == null || _isEnhancing) return;
    final l10n = AppLocalizations.of(context)!;

    setState(() => _isEnhancing = true);
    ConduitHaptics.lightImpact();
    try {
      final result = await enhanceNote(_container, _contentMarkdown);
      if (!mounted) return;
      switch (result.outcome) {
        case NoteAiOutcome.done:
          setState(() {
            _installContentDocument(documentFromMarkdown(result.text!));
          });
          // _installContentDocument deliberately leaves _savedMarkdown
          // untouched, so the enhanced content now differs from the saved
          // baseline; re-run change detection to flag the enhancement for
          // auto-save.
          _onContentChanged();
          ConduitHaptics.mediumImpact();
          AdaptiveSnackBar.show(
            context,
            message: l10n.noteEnhanced,
            type: AdaptiveSnackBarType.success,
            duration: const Duration(seconds: 2),
          );
        case NoteAiOutcome.noContent:
          _showError(l10n.noContentToEnhance);
        case NoteAiOutcome.noModel:
          _showError(l10n.noModelSelected);
        case NoteAiOutcome.failed:
          _showError(l10n.failedToEnhanceNote);
        case NoteAiOutcome.unavailable:
        case NoteAiOutcome.empty:
          break;
      }
    } finally {
      if (mounted) {
        setState(() => _isEnhancing = false);
      }
    }
  }

  // Voice dictation
  Future<void> _toggleDictation() async {
    if (_isRecording) {
      await _stopDictation();
    } else {
      await _startDictation();
    }
  }

  Future<void> _startDictation() async {
    // Use the shared service, as the chat composer does, so dictation honours
    // the user's speech-to-text preference (e.g. server-only) and locale.
    _voiceService ??= ref.read(voiceInputServiceProvider);

    try {
      final ok = await _voiceService!.initialize();
      if (!mounted) return;
      if (!ok) {
        _showError(AppLocalizations.of(context)!.voiceInputUnavailable);
        return;
      }

      final stream = await _voiceService!.beginListening();
      if (!mounted) {
        // The editor closed while listening was starting. Capture is already
        // running and dispose() saw no dictation to stop, so stop it here.
        unawaited(_voiceService?.stopListening());
        return;
      }

      // Anchor the dictation run at the current selection. The trailing
      // line-break of a Parchment document is not editable, so clamp before
      // it.
      final controller = _contentController;
      if (controller == null) {
        _dictationRun = null;
      } else {
        final selection = controller.selection;
        final docEnd = (controller.document.length - 1).clamp(
          0,
          controller.document.length,
        );
        _dictationRun = selection.isValid
            ? NoteDictationRun.at(
                selectionBase: selection.baseOffset,
                selectionExtent: selection.extentOffset,
                textLength: docEnd,
              )
            : NoteDictationRun(anchor: docEnd);
      }

      setState(() {
        _isRecording = true;
      });

      ConduitHaptics.lightImpact();

      _voiceSub?.cancel();
      _voiceSub = stream.listen(
        (text) {
          if (!mounted) return;
          _applyDictationText(text);
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _isRecording = false);
        },
        onError: (_) {
          if (!mounted) return;
          setState(() => _isRecording = false);
        },
      );
    } catch (e) {
      _showError(AppLocalizations.of(context)!.failedToStartDictation);
      if (mounted) {
        setState(() => _isRecording = false);
      }
    }
  }

  Future<void> _stopDictation() async {
    await _voiceService?.stopListening();
    _voiceSub?.cancel();
    _dictationRun = null;
    if (mounted) {
      setState(() => _isRecording = false);
      ConduitHaptics.selectionClick();
    }
  }

  /// Applies the latest (cumulative) dictation [transcript] by replacing the
  /// previously inserted run with the new text, leaving the rest of the
  /// document -- and its formatting -- untouched.
  void _applyDictationText(String transcript) {
    final controller = _contentController;
    final run = _dictationRun;
    if (controller == null || run == null) return;

    final edit = run.update(controller.document.toPlainText(), transcript);
    controller.replaceText(
      edit.start,
      edit.deleteLength,
      edit.insert,
      selection: TextSelection.collapsed(offset: edit.caret),
    );
  }

  /// Shows a bottom sheet to choose between dictation and audio recording.
  void _showRecordingOptions() async {
    final conduitTheme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    if (Platform.isIOS) {
      try {
        final selection = await IosNativeDropdownBridge.instance
            .showFromContext(
              context: context,
              title: l10n.recordAudio,
              cancelLabel: l10n.cancel,
              options: [
                IosNativeDropdownOption(
                  id: 'dictation',
                  label: l10n.dictation,
                  subtitle: l10n.dictationDescription,
                  sfSymbol: 'keyboard',
                ),
                IosNativeDropdownOption(
                  id: 'record-audio',
                  label: l10n.recordAudio,
                  subtitle: l10n.recordAudioDescription,
                  sfSymbol: 'mic.fill',
                ),
              ],
              rethrowErrors: true,
            );
        switch (selection) {
          case 'dictation':
            _toggleDictation();
          case 'record-audio':
            _showAudioRecordingOverlay();
          default:
            break;
        }
        return;
      } catch (_) {
        if (!mounted) {
          return;
        }
      }
    }

    if (!mounted) {
      return;
    }

    ThemedSheets.showSurface<void>(
      context: context,
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Dictation option
          AdaptiveListTile(
            leading: SizedBox(
              width: IconSize.xl,
              height: IconSize.xl,
              child: Icon(
                Platform.isIOS
                    ? CupertinoIcons.keyboard
                    : Icons.keyboard_voice_rounded,
                color: conduitTheme.textPrimary,
                size: IconSize.md,
              ),
            ),
            title: Text(
              l10n.dictation,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: conduitTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              l10n.dictationDescription,
              style: AppTypography.bodySmallStyle.copyWith(
                color: conduitTheme.textSecondary,
              ),
            ),
            onTap: () {
              Navigator.pop(context);
              _toggleDictation();
            },
          ),
          const SizedBox(height: Spacing.xs),
          // Audio recording option
          AdaptiveListTile(
            leading: SizedBox(
              width: IconSize.xl,
              height: IconSize.xl,
              child: Icon(
                Platform.isIOS ? CupertinoIcons.mic : Icons.mic_none_rounded,
                color: conduitTheme.textPrimary,
                size: IconSize.md,
              ),
            ),
            title: Text(
              l10n.recordAudio,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: conduitTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              l10n.recordAudioDescription,
              style: AppTypography.bodySmallStyle.copyWith(
                color: conduitTheme.textSecondary,
              ),
            ),
            onTap: () {
              Navigator.pop(context);
              _showAudioRecordingOverlay();
            },
          ),
        ],
      ),
    );
  }

  /// Shows the full-screen audio recording overlay.
  void _showAudioRecordingOverlay() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: false,
        pageBuilder: (context, animation, secondaryAnimation) {
          return FadeTransition(
            opacity: animation,
            child: AudioRecordingOverlay(
              onCancel: () => Navigator.pop(context),
              onConfirm: (file) async {
                final staged = await _attachments.stage(file);
                if (staged && context.mounted) Navigator.pop(context);
                return staged;
              },
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 150),
      ),
    );
  }

  void _copyToClipboard() {
    final l10n = AppLocalizations.of(context)!;
    final content = _contentMarkdown;
    Clipboard.setData(ClipboardData(text: content));
    ConduitHaptics.selectionClick();
    AdaptiveSnackBar.show(
      context,
      message: l10n.noteCopiedToClipboard,
      type: AdaptiveSnackBarType.success,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Check if notes feature is enabled - redirect to chat if disabled
    final notesEnabled = ref.watch(notesFeatureEnabledProvider);
    if (!notesEnabled) {
      // Redirect back to chat on next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.go('/chat');
        }
      });
      // Show empty scaffold while redirecting
      return const AdaptiveRouteShell(body: SizedBox.shrink());
    }

    return PopScope(
      // Allow the back gesture/animation to proceed normally when there is
      // nothing to save. When an edit is still pending (within the auto-save
      // debounce), intercept the pop, flush the save while the widget is still
      // mounted (so the durable write completes without racing teardown), then
      // pop programmatically.
      canPop: !_hasChanges,
      onPopInvokedWithResult: _onEditorPopInvoked,
      child: AdaptiveRouteShell(
        backgroundColor: context.conduitTheme.surfaceBackground,
        extendBodyBehindAppBar: true,
        appBar: _buildAdaptiveNoteEditorAppBar(context),
        body: Stack(
          children: [
            Positioned.fill(child: _buildMainContent(context)),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: ConduitChromeGradientFade.top(
                contentHeight:
                    MediaQuery.viewPaddingOf(context).top +
                    conduitAdaptiveToolbarHeightOf(context),
              ),
            ),
            if (!_isLoading && _note != null)
              Positioned(
                top:
                    MediaQuery.of(context).padding.top +
                    conduitAdaptiveToolbarHeightOf(context),
                left: 0,
                right: 0,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.xs),
                  child: Center(child: _buildFloatingMetadataBar(context)),
                ),
              ),
            if (!_isLoading && _note != null && !_contentFocusNode.hasFocus)
              Positioned(
                left: Spacing.md,
                right: Spacing.md,
                bottom: Spacing.md + MediaQuery.of(context).padding.bottom,
                child: NoteFloatingActions(
                  isRecording: _isRecording,
                  isUploadingAudio: _attachments.isUploading,
                  isEnhancing: _isEnhancing,
                  onVoicePressed: _isRecording
                      ? _toggleDictation
                      : _showRecordingOptions,
                  onEnhance: _enhanceContent,
                  onGenerateTitle: _generateTitle,
                ),
              ),
            // Formatting toolbar — shown above the keyboard while the content
            // editor is focused (in place of the floating actions row). The
            // scaffold uses resizeToAvoidBottomInset, so the body is already
            // laid out above the keyboard; anchoring at bottom: 0 sits the
            // toolbar directly on top of it (anchoring at viewInsets.bottom
            // would double-count the inset and push it up to the stats row).
            if (!_isLoading && _note != null && _contentFocusNode.hasFocus)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildFormattingToolbar(context),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormattingToolbar(BuildContext context) {
    final theme = context.conduitTheme;
    final controller = _contentController;
    if (controller == null) return const SizedBox.shrink();
    return Material(
      color: theme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: theme.cardBorder, width: BorderWidth.thin),
            ),
          ),
          child: FleatherTheme(
            data: _fleatherTheme ??= _buildFleatherTheme(context),
            // Markdown is the canonical stored format, so hide every control
            // whose result markdown can't represent — otherwise the user
            // applies formatting that silently vanishes on save/reopen.
            // Dropped: underline, text/background colour, alignment,
            // indentation, and text direction. Kept: bold, italic,
            // strikethrough, inline code, headings, lists (incl. checkboxes),
            // code blocks, quotes, links, and horizontal rules.
            child: FleatherToolbar.basic(
              controller: controller,
              hideUnderLineButton: true,
              hideBackgroundColor: true,
              hideForegroundColor: true,
              hideAlignment: true,
              hideIndentation: true,
              hideDirection: true,
            ),
          ),
        ),
      ),
    );
  }

  AdaptiveAppBar _buildAdaptiveNoteEditorAppBar(BuildContext context) {
    final tintColor = context.conduitTheme.textPrimary;
    final l10n = AppLocalizations.of(context)!;
    final maxTitleWidth = resolveConduitAdaptiveLeadingPillWidth(
      context,
      trailingActionCount: 1,
      maxWidth: kConduitAdaptiveToolbarMaxPillWidth,
    );
    final menuItems = _buildNoteEditorToolbarMenuItems(l10n);
    final actions = _buildNoteEditorToolbarActionWidgets(context, menuItems);
    final nativeMenuAction = buildConduitNativeToolbarMenuAction<String>(
      iosSymbol: 'ellipsis',
      accessibilityLabel: MaterialLocalizations.of(context).moreButtonTooltip,
      tintColor: tintColor,
      items: menuItems,
      onSelected: _handleEditorToolbarMenuSelection,
    );
    final useNativeActionGroup =
        Platform.isIOS &&
        conduitSupportsNativeGlass() &&
        nativeMenuAction != null;

    return buildConduitCenteredAdaptiveAppBar(
      context: context,
      tintColor: tintColor,
      leading: ConduitAdaptiveAppBarIconButton(
        icon: Platform.isIOS ? CupertinoIcons.line_horizontal_3 : Icons.menu,
        iosSymbol: 'line.3.horizontal',
        semanticLabel: AppLocalizations.of(context)!.sidebarButtonLabel,
        onPressed: () =>
            SidebarDrawerControllerScope.maybeOf(context)?.toggle(),
        iconColor: tintColor,
      ),
      title: _buildNoteEditorTitlePill(context, maxWidth: maxTitleWidth),
      actions: actions,
      cupertinoTrailing: useNativeActionGroup
          ? ConduitNativeToolbarActionGroup(actions: [nativeMenuAction])
          : Row(mainAxisSize: MainAxisSize.min, children: actions),
      centerTitle: false,
    );
  }

  List<AdaptivePopupMenuEntry> _buildNoteEditorToolbarMenuItems(
    AppLocalizations l10n,
  ) {
    return [
      AdaptivePopupMenuItem<String>(
        value: 'generate',
        label: l10n.generateTitle,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'sparkles',
          materialIcon: Icons.auto_awesome,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'copy',
        label: l10n.copy,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'doc.on.doc',
          materialIcon: Icons.copy_outlined,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'pin',
        label: _note?.isPinned == true ? l10n.unpin : l10n.pin,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: _note?.isPinned == true ? 'pin.slash' : 'pin',
          materialIcon: Icons.push_pin_outlined,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'delete',
        label: l10n.delete,
        isDestructive: true,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'trash',
          materialIcon: Icons.delete_outline,
        ),
      ),
    ];
  }

  List<Widget> _buildNoteEditorToolbarActionWidgets(
    BuildContext context,
    List<AdaptivePopupMenuEntry> menuItems,
  ) {
    return buildConduitAdaptiveToolbarActionWidgets([
      ConduitAdaptiveToolbarOverflowButton<String>(
        tintColor: context.conduitTheme.textPrimary,
        items: menuItems,
        onSelected: _handleEditorToolbarMenuSelection,
      ),
    ]);
  }

  void _handleEditorToolbarMenuSelection(String value) {
    switch (value) {
      case 'generate':
        ConduitHaptics.selectionClick();
        _generateTitle();
        return;
      case 'copy':
        ConduitHaptics.selectionClick();
        _copyToClipboard();
        return;
      case 'pin':
        _togglePin();
        return;
      case 'delete':
        ConduitHaptics.mediumImpact();
        _deleteNote();
        return;
    }
  }

  Widget _buildNoteEditorTitlePill(
    BuildContext context, {
    required double maxWidth,
  }) {
    final conduitTheme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final titleTextStyle = conduitAdaptiveToolbarLeadingTitleTextStyle(context);
    final controlExtent = conduitScaledControlExtent(context);
    final titleLabel = _isGeneratingTitle
        ? l10n.generatingTitle
        : (_titleController.text.isEmpty
              ? l10n.untitled
              : _titleController.text);
    final trailingWidth = _isSaving
        ? Spacing.sm + IconSize.sm
        : (_hasChanges ? Spacing.sm + 8 : 0.0);
    const horizontalInset = 10.0;
    final targetWidth = resolveConduitAdaptiveTextPillWidth(
      context: context,
      label: titleLabel,
      textStyle: titleTextStyle,
      maxWidth: maxWidth,
      minWidth: 96,
      horizontalPadding: horizontalInset * 2,
      trailingWidth: trailingWidth,
    );

    return buildConduitAdaptiveToolbarPillSurface(
      width: targetWidth,
      height: controlExtent,
      onPressed: _isGeneratingTitle
          ? null
          : () => _titleFocusNode.requestFocus(),
      semanticLabel: titleLabel,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: controlExtent),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: horizontalInset),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: _isGeneratingTitle
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: IconSize.sm,
                            height: IconSize.sm,
                            child: CircularProgressIndicator(
                              strokeWidth: BorderWidth.medium,
                              valueColor: AlwaysStoppedAnimation(
                                conduitTheme.loadingIndicator,
                              ),
                            ),
                          ),
                          const SizedBox(width: Spacing.sm),
                          Text(
                            l10n.generatingTitle,
                            style: titleTextStyle.copyWith(
                              color: conduitTheme.textSecondary,
                            ),
                          ),
                        ],
                      )
                    : Stack(
                        alignment: Alignment.center,
                        children: [
                          Opacity(
                            opacity: _titleFocusNode.hasFocus ? 1.0 : 0.0,
                            child: IntrinsicWidth(
                              child: AdaptiveTextField(
                                controller: _titleController,
                                focusNode: _titleFocusNode,
                                enabled: !_isGeneratingTitle,
                                style: titleTextStyle,
                                placeholder: l10n.untitled,
                                textAlign: TextAlign.center,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) =>
                                    _contentFocusNode.requestFocus(),
                                padding: EdgeInsets.zero,
                                cupertinoDecoration: const BoxDecoration(),
                                decoration: context.conduitInputStyles
                                    .borderless(hint: l10n.untitled)
                                    .copyWith(
                                      hintStyle: titleTextStyle.copyWith(
                                        color: conduitTheme.textSecondary
                                            .withValues(alpha: 0.6),
                                        fontWeight: FontWeight.w300,
                                      ),
                                      contentPadding: EdgeInsets.zero,
                                      isDense: true,
                                    ),
                              ),
                            ),
                          ),
                          if (!_titleFocusNode.hasFocus)
                            GestureDetector(
                              onTap: () => _titleFocusNode.requestFocus(),
                              child: MiddleEllipsisText(
                                _titleController.text.isEmpty
                                    ? l10n.untitled
                                    : _titleController.text,
                                style: titleTextStyle.copyWith(
                                  color: _titleController.text.isEmpty
                                      ? conduitTheme.textSecondary.withValues(
                                          alpha: 0.6,
                                        )
                                      : conduitTheme.textPrimary,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              if (_hasChanges && !_isSaving)
                Padding(
                  padding: const EdgeInsets.only(left: Spacing.sm),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: conduitTheme.warning,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              if (_isSaving)
                Padding(
                  padding: const EdgeInsets.only(left: Spacing.sm),
                  child: SizedBox(
                    width: IconSize.sm,
                    height: IconSize.sm,
                    child: CircularProgressIndicator(
                      strokeWidth: BorderWidth.medium,
                      valueColor: AlwaysStoppedAnimation(
                        conduitTheme.loadingIndicator,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingMetadataBar(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final dateFormat = DateFormat.MMMd();
    final timeFormat = DateFormat.jm();
    final createdDate = _note != null
        ? '${dateFormat.format(_note!.createdDateTime)} ${timeFormat.format(_note!.createdDateTime)}'
        : '';

    final borderRadius = BorderRadius.circular(AppBorderRadius.pill);
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildMetadataChip(
            context,
            icon: Platform.isIOS
                ? CupertinoIcons.calendar
                : Icons.calendar_today_rounded,
            label: createdDate,
          ),
          _buildMetadataSeparator(context),
          _buildMetadataChip(
            context,
            icon: Platform.isIOS
                ? CupertinoIcons.doc_text
                : Icons.article_rounded,
            label: l10n.wordCount(_cachedWordCount),
          ),
          _buildMetadataSeparator(context),
          _buildMetadataChip(
            context,
            icon: Platform.isIOS
                ? CupertinoIcons.textformat_abc
                : Icons.text_fields_rounded,
            label: l10n.charCount(_charCount),
          ),
        ],
      ),
    );

    final theme = context.conduitTheme;
    if (conduitSupportsNativeGlass()) {
      return Stack(
        key: const ValueKey<String>('note-metadata-native-glass'),
        children: [
          Positioned.fill(
            child: AdaptiveGlassBackdrop(borderRadius: borderRadius),
          ),
          content,
        ],
      );
    }

    return Container(
      key: const ValueKey<String>('note-metadata-fallback-surface'),
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: borderRadius,
        border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
      ),
      child: content,
    );
  }

  Widget _buildMetadataSeparator(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xxs),
      child: Text(
        '·',
        style: AppTypography.tiny.copyWith(
          color: context.conduitTheme.textSecondary.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _buildMetadataChip(
    BuildContext context, {
    required IconData icon,
    required String label,
  }) {
    final secondaryColor = context.conduitTheme.textSecondary;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.xs,
        vertical: Spacing.xxs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: secondaryColor, size: IconSize.xs),
          const SizedBox(width: Spacing.xxs),
          Text(
            label,
            style: AppTypography.tiny.copyWith(
              color: secondaryColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent(BuildContext context) {
    return _buildBody(context);
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return Center(
        child: ImprovedLoadingState(
          message: AppLocalizations.of(context)!.loadingNote,
        ),
      );
    }

    if (_note == null) {
      return _buildNotFoundState(context);
    }

    // Title is now edited in the app bar pill, so just show the content editor
    return _buildEditor(context);
  }

  Widget _buildEditor(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    // Adaptive app bar height + metadata bar (~40).
    final appBarHeight = conduitAdaptiveToolbarHeightOf(context) + 40;

    // Get attached files
    final files = _note?.data.files ?? [];

    return GestureDetector(
      onTap: () => _contentFocusNode.requestFocus(),
      behavior: HitTestBehavior.opaque,
      child: RefreshIndicator.adaptive(
        onRefresh: _refreshNote,
        edgeOffset: topPadding + appBarHeight + Spacing.sm,
        child: SingleChildScrollView(
          controller: _scrollController,
          // Always scrollable so pull-to-refresh works even when the note is
          // short enough to fit on screen.
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            Spacing.inputPadding,
            topPadding +
                appBarHeight +
                Spacing.sm, // Space for floating app bar
            Spacing.inputPadding,
            120, // Extra padding for floating buttons
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // File attachments section (including durable pending audio).
              if (files.isNotEmpty || _attachments.pending.isNotEmpty) ...[
                _buildAttachmentsSection(context, files),
                const SizedBox(height: Spacing.lg),
              ],
              // Content editor
              _buildContentEditor(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentsSection(
    BuildContext context,
    List<Map<String, dynamic>> files,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final pendingUploads = _attachments.pending;
    final total = files.length + pendingUploads.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: Spacing.xs, bottom: Spacing.xs),
          child: Row(
            children: [
              Icon(
                Platform.isIOS
                    ? CupertinoIcons.paperclip
                    : Icons.attach_file_rounded,
                size: IconSize.sm,
                color: theme.textSecondary,
              ),
              const SizedBox(width: Spacing.xs),
              Text(
                l10n.attachments,
                style: AppTypography.labelStyle.copyWith(
                  color: theme.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.xs,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: theme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppBorderRadius.xs),
                ),
                child: Text(
                  '$total',
                  style: AppTypography.captionStyle.copyWith(
                    color: theme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        ...pendingUploads.map(
          (item) => _buildPendingAudioAttachment(context, item),
        ),
        ...files.map(
          (file) => Padding(
            padding: const EdgeInsets.only(bottom: Spacing.xs),
            child: NoteFileAttachment(
              file: file,
              onTap: () => _playAudioFile(file),
              onDelete: () => _removeFile(file),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPendingAudioAttachment(
    BuildContext context,
    PendingNoteAudioUpload item,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final inFlight = _attachments.isInFlight(item.id);
    final failed = item.status == NoteAudioUploadStatus.failed && !inFlight;
    final retryable = !inFlight;
    final localFile = <String, dynamic>{
      'type': 'audio',
      'name': item.fileName,
      'size': item.fileSize,
      '_localPath': item.localPath,
      '_localAudioUploadId': item.id,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NoteFileAttachment(
            file: localFile,
            showDelete: !inFlight && item.serverFileId == null,
            onTap: inFlight ? null : () => _playAudioFile(localFile),
            onDelete: () => _removeFile(localFile),
          ),
          Padding(
            padding: const EdgeInsets.only(left: Spacing.sm),
            child: Row(
              children: [
                if (failed)
                  Icon(
                    Platform.isIOS
                        ? CupertinoIcons.exclamationmark_circle_fill
                        : Icons.error_rounded,
                    size: IconSize.sm,
                    color: theme.error,
                  )
                else
                  ConduitLoading.inline(
                    size: IconSize.sm,
                    color: theme.loadingIndicator,
                    context: context,
                  ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    failed
                        ? l10n.failedToUploadAudio
                        : l10n.processingRecording,
                    style: AppTypography.captionStyle.copyWith(
                      color: failed ? theme.error : theme.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ConduitIconButton(
                  icon: Platform.isIOS ? CupertinoIcons.share : Icons.ios_share,
                  iconColor: theme.textSecondary,
                  tooltip: l10n.shareSystemSheet,
                  onPressed: inFlight ? null : () => _sharePendingAudio(item),
                  isCompact: true,
                ),
                if (retryable)
                  ConduitIconButton(
                    icon: Platform.isIOS
                        ? CupertinoIcons.arrow_clockwise
                        : Icons.refresh_rounded,
                    iconColor: theme.buttonPrimary,
                    tooltip: l10n.retry,
                    onPressed: () => unawaited(
                      _attachments.retry(
                        ids: <String>[item.id],
                        showFeedback: true,
                      ),
                    ),
                    isCompact: true,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sharePendingAudio(PendingNoteAudioUpload item) async {
    final l10n = AppLocalizations.of(context)!;
    final renderObject = context.findRenderObject();
    final shareOrigin = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    try {
      if (!await File(item.localPath).exists()) {
        throw StateError('The saved recording file is missing');
      }
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[
            XFile(
              item.localPath,
              mimeType: noteAudioContentType(item.fileName),
              name: item.fileName,
            ),
          ],
          fileNameOverrides: <String>[item.fileName],
          sharePositionOrigin: shareOrigin,
        ),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-audio-share-failed',
        scope: 'notes/audio',
        error: error,
        stackTrace: stackTrace,
        data: {'id': item.id},
      );
      if (mounted) _showError(l10n.errorMessage);
    }
  }

  /// Pull-to-refresh handler: syncs the note with the server, then reloads it
  /// into the editor.
  ///
  /// Order matters. We first flush any pending local edit, then run a full sync
  /// cycle (push the outbox + pull the server) before re-reading. Re-reading
  /// without syncing would let the detail fetch return a server copy that is
  /// behind a not-yet-synced local edit and clobber it with stale/empty content.
  Future<void> _refreshNote() async {
    final noteBeforeRefresh = _note;
    final hadDraftChanges =
        noteBeforeRefresh != null &&
        (_titleController.text != noteBeforeRefresh.title ||
            _contentMarkdown != _savedMarkdown);
    if (_hasChanges) {
      _saveDebounce?.cancel();
      await _autoSave();
    }
    if (!mounted) return;

    // Push local changes and pull remote ones so the local row reflects both
    // sides. Mirrors the notes-list pull-to-refresh.
    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);
    final authEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    final userId = ref.read(currentUserProvider2)?.id;
    if (db == null) return;
    try {
      final syncEngine = ref.read(syncEngineProvider.notifier);
      await syncEngine.requestPull(reason: 'note-editor-refresh');
      await syncEngine.reconcileNow();
    } catch (_) {
      // Best-effort; still reload from the (at least locally-current) row below.
    }
    if (!mounted ||
        !_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
      return;
    }

    // Re-read from the reconciled LOCAL row, not a fresh server fetch: the pull
    // has already merged remote edits into it, and reading the row avoids a
    // server copy that's behind a not-yet-pushed local edit clobbering it.
    try {
      // The note is already open in the current session, so an id-scoped read is
      // safe here (avoids pulling auth providers into the editor just for the
      // user id).
      final currentNoteId = _note?.id ?? widget.noteId;
      final resolvedNoteId = await db.notesDao.resolveNoteRemapTarget(
        currentNoteId,
      );
      final note = await readLocalNote(db, resolvedNoteId);
      if (!mounted ||
          !_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
        return;
      }
      if (note == null) {
        // The user may have typed while the pull/reconcile/read was in flight.
        // Recover those edits as a new local note because the reconciler has
        // already removed the old row and an update could no longer persist.
        if (hadDraftChanges || _hasChanges) {
          if (!_hasChanges) setState(() => _hasChanges = true);
          await _recovery.recover(
            NoteRecoverySession(
              api: api,
              db: db,
              authEpoch: authEpoch,
              userId: userId,
            ),
          );
          return;
        }
        ref.invalidate(noteByIdProvider(currentNoteId));
        if (resolvedNoteId != currentNoteId) {
          ref.invalidate(noteByIdProvider(resolvedNoteId));
        }
        setState(() {
          _note = null;
          _titleController.clear();
          _installContentDocument(documentFromMarkdown(''));
          _savedMarkdown = '';
          _cachedWordCount = 0;
          _hasChanges = false;
        });
        return;
      }
      // If the user typed while the sync/read was in flight, do NOT overwrite
      // their in-progress edits: those keystroke(s) re-set `_hasChanges` and
      // queued a fresh debounce. Bail out and leave the editor as-is so that
      // debounce saves them — overwriting here would discard them silently.
      // (No await between this check and the setState below, so nothing can
      // sneak in.)
      if (_hasChanges) return;
      // Keep the detail cache consistent with what we just loaded.
      ref.invalidate(noteByIdProvider(currentNoteId));
      if (resolvedNoteId != currentNoteId) {
        ref.invalidate(noteByIdProvider(resolvedNoteId));
      }
      setState(() {
        _note = note;
        _titleController.text = note.title;
        _installContentDocument(documentFromMarkdown(note.markdownContent));
        _savedMarkdown = _contentMarkdown;
        _updateWordCount();
      });
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Widget _buildContentEditor(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final controller = _contentController;
    if (controller == null) {
      return const SizedBox.shrink();
    }

    final editor = HorizontalGestureExclusion(
      child: FleatherEditor(
        controller: controller,
        focusNode: _contentFocusNode,
        // Lives inside the page's SingleChildScrollView; the editor must not
        // scroll independently so the whole note grows with the content. Give
        // Fleather the parent controller so context-menu actions can reveal the
        // selection without reading an unattached internal ScrollController.
        scrollController: _scrollController,
        scrollable: false,
        expands: false,
        padding: EdgeInsets.zero,
        minHeight: 20 * 1.8 * AppTypography.bodyLarge,
        textCapitalization: TextCapitalization.sentences,
      ),
    );

    // Fleather has no built-in placeholder, so overlay a hint while the
    // document is empty.
    final showPlaceholder = _contentPlainText.isEmpty;
    return FleatherTheme(
      data: _fleatherTheme ??= _buildFleatherTheme(context),
      child: Stack(
        children: [
          if (showPlaceholder)
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: IgnorePointer(
                child: Text(
                  l10n.writeNote,
                  style: AppTypography.bodyLargeStyle.copyWith(
                    color: theme.textSecondary.withValues(alpha: 0.35),
                    height: 1.8,
                  ),
                ),
              ),
            ),
          editor,
        ],
      ),
    );
  }

  /// Builds a Fleather theme derived from the app's typography and colours so
  /// the rich-text editor matches the rest of the note UI.
  FleatherThemeData _buildFleatherTheme(BuildContext context) {
    return buildNoteEditorFleatherTheme(context);
  }

  /// Play an audio file attachment.
  Future<void> _playAudioFile(Map<String, dynamic> file) async {
    final localPath = file['_localPath']?.toString();
    if (localPath != null && localPath.isNotEmpty) {
      final l10n = AppLocalizations.of(context)!;
      if (!await File(localPath).exists()) {
        if (mounted) _showError(l10n.fileNotFound);
        return;
      }
      if (!mounted) return;
      await AudioPlayerDialog.showLocal(
        context,
        filePath: localPath,
        fileName: file['name']?.toString() ?? 'Audio Recording',
      );
      return;
    }

    final fileId = file['id']?.toString();
    if (fileId == null) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    final fileName = file['name']?.toString() ?? 'Audio Recording';

    await AudioPlayerDialog.show(
      context,
      fileId: fileId,
      api: api,
      fileName: fileName,
    );
  }

  /// Remove a file attachment from the note.
  Future<void> _removeFile(Map<String, dynamic> file) async {
    final l10n = AppLocalizations.of(context)!;

    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.removeFile,
      message: l10n.removeFileConfirm,
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    );

    if (confirmed != true || _note == null) return;

    final localUploadId = file['_localAudioUploadId']?.toString();
    if (localUploadId != null && localUploadId.isNotEmpty) {
      await _attachments.removePending(localUploadId);
      return;
    }

    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);
    if (api == null && db == null) return;

    setState(() => _isSaving = true);

    try {
      final updatedNote = await _attachments.removeAttachedFile(
        file['id']?.toString(),
      );

      if (mounted) {
        if (updatedNote != null) {
          setState(() {
            _note = updatedNote;
            _isSaving = false;
          });

          ConduitHaptics.lightImpact();
          AdaptiveSnackBar.show(
            context,
            message: l10n.fileRemoved,
            type: AdaptiveSnackBarType.success,
            duration: const Duration(seconds: 2),
          );
        } else {
          setState(() => _isSaving = false);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        _showError(e.toString());
      }
    }
  }

  /// Notes open with `go`, so the editor is often the only page in its
  /// navigator; popping it would leave nothing on screen.
  void _leaveMissingNote() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      context.go('/chat');
    }
  }

  Widget _buildNotFoundState(BuildContext context) {
    final theme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final l10n = AppLocalizations.of(context)!;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: sidebarTheme.tint.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppBorderRadius.xl),
              ),
              child: Icon(
                Platform.isIOS
                    ? CupertinoIcons.doc_text
                    : Icons.description_outlined,
                size: 36,
                color: sidebarTheme.foreground.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: Spacing.lg),
            Text(
              l10n.noteNotFound,
              style: AppTypography.headlineSmallStyle.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.lg),
            AdaptiveButton.child(
              onPressed: _leaveMissingNote,
              color: sidebarTheme.primary,
              style: AdaptiveButtonStyle.bordered,
              borderRadius: BorderRadius.circular(AppBorderRadius.button),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Platform.isIOS
                        ? CupertinoIcons.back
                        : Icons.arrow_back_rounded,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Text(l10n.goBack),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
