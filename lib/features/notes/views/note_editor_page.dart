import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/auth/api_auth_interceptor.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/database/mappers/note_mapper.dart';
import '../../../core/models/note.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/services/ios_native_dropdown_bridge.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../core/sync/chat_locks.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../chat/services/voice_input_service.dart';
import '../providers/notes_providers.dart';
import '../services/note_audio_upload_service.dart';
import '../utils/note_document_codec.dart';
import '../widgets/audio_player_dialog.dart';
import '../widgets/audio_recording_overlay.dart';
import '../widgets/note_file_attachment.dart';

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
  bool _isUploadingAudio = false;
  Note? _note;

  final NoteAudioUploadStore _noteAudioUploadStore = NoteAudioUploadStore();
  final List<PendingNoteAudioUpload> _pendingAudioUploads = [];
  final Set<String> _audioUploadsInFlight = <String>{};
  final Set<String> _queuedAudioUploadIds = <String>{};
  final Set<String> _audioUploadFeedbackIds = <String>{};
  final Set<String> _hiddenAudioUploadIds = <String>{};
  int _pendingAudioMutationGeneration = 0;
  bool _isDrainingAudioUploads = false;
  ProviderSubscription<ConnectivityStatus>? _audioConnectivitySubscription;
  ProviderSubscription<Object>? _audioAuthEpochSubscription;
  CancelToken? _activeAudioCancelToken;

  // Voice input
  VoiceInputService? _voiceService;
  StreamSubscription<String>? _voiceSub;
  // Index in the document where the in-progress dictation run is inserted, and
  // the length of that run, so each (cumulative) transcript update replaces the
  // previous one without disturbing the rest of the document.
  int? _dictationAnchor;
  int _dictationLength = 0;

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
    _loadNote();
    _audioConnectivitySubscription = ref.listenManual<ConnectivityStatus>(
      connectivityStatusProvider,
      (previous, next) {
        if (previous == ConnectivityStatus.offline &&
            next == ConnectivityStatus.online) {
          unawaited(_retryPendingAudioUploads());
        }
      },
    );
    _audioAuthEpochSubscription = ref.listenManual<Object>(
      openWebUiAuthSessionEpochProvider,
      (previous, next) {
        _activeAudioCancelToken?.cancel('Authentication session changed.');
        _activeAudioCancelToken = null;
        _queuedAudioUploadIds.clear();
        _audioUploadFeedbackIds.clear();
        _audioUploadsInFlight.clear();
        _hiddenAudioUploadIds.clear();
        _pendingAudioMutationGeneration++;
        if (mounted) {
          setState(_pendingAudioUploads.clear);
          if (_note != null) unawaited(_loadPendingAudioUploads());
        }
      },
    );
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
    controller.addListener(_onContentChanged);
    _contentController = controller;
    previous?.removeListener(_onContentChanged);
    previous?.dispose();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _voiceSub?.cancel();
    _audioConnectivitySubscription?.close();
    _audioAuthEpochSubscription?.close();
    _activeAudioCancelToken?.cancel('Note editor disposed.');
    _voiceService?.stopListening();
    _titleController.dispose();
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
  }) {
    if (!ref.read(isAuthenticatedProvider2)) return false;
    if (!identical(ref.read(apiServiceProvider), api)) return false;
    if (authEpoch != null &&
        !identical(ref.read(openWebUiAuthSessionEpochProvider), authEpoch)) {
      return false;
    }
    final currentDb = ref.read(appDatabaseProvider);
    return db == null ? currentDb == null : identical(currentDb, db);
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
        unawaited(_loadPendingAudioUploads());
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
    _saveDebounce = Timer(const Duration(milliseconds: 800), _autoSave);
  }

  /// Handles a back-navigation attempt. Reached only when [canPop] was false,
  /// i.e. there is a pending edit: flush it while still mounted (so the durable
  /// write doesn't race teardown), then pop programmatically.
  Future<void> _onEditorPopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    _saveDebounce?.cancel();
    await _autoSave();
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(result);
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
      final document = _contentController?.document;
      final markdown = document != null ? markdownFromDocument(document) : '';
      final html = document != null ? htmlFromDocument(document) : '';
      // `json` (TipTap) is intentionally left null: markdown stays the
      // canonical interchange format so notes remain editable on the Open
      // WebUI web client.
      data['content'] = <String, dynamic>{
        'json': null,
        'html': html,
        'md': markdown,
      };
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
    if (!_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
      return null;
    }
    Note? note;
    if (db != null) {
      note = await durableUpdateNote(
        ref,
        db,
        id: widget.noteId,
        title: title,
        data: data,
      );
    } else {
      // Session confirmed current, so the live API equals the captured one.
      final currentApi = ref.read(apiServiceProvider);
      if (currentApi == null) return null;
      note = Note.fromJson(
        await currentApi.updateNoteForSession(
          widget.noteId,
          title: title,
          data: data,
          authSnapshot: authSnapshot,
          cancelToken: cancelToken,
        ),
      );
      if (mounted &&
          _isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
        ref.read(notesListProvider.notifier).updateNote(note, sourceDb: db);
      }
    }
    // `noteByIdProvider` is keepAlive, so without this it keeps serving the
    // note as it was when first opened (e.g. empty for a freshly created note)
    // and reopening the note in the same app session shows stale/empty content
    // until a full restart. Invalidate so the next open re-reads what we just
    // saved. Cover the remapped server id too, in case a `local:` id resolved.
    if (note != null &&
        _isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
      ref.invalidate(noteByIdProvider(widget.noteId));
      if (note.id != widget.noteId) {
        ref.invalidate(noteByIdProvider(note.id));
      }
    }
    return note;
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
    if (_note == null) return;

    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.deleteNoteTitle,
      message: l10n.deleteNoteMessage(
        _note!.title.isEmpty ? l10n.untitled : _note!.title,
      ),
      confirmText: l10n.delete,
      isDestructive: true,
    );

    if (confirmed && mounted) {
      ConduitHaptics.mediumImpact();
      final success = await ref
          .read(noteDeleterProvider.notifier)
          .deleteNote(widget.noteId);
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

  // Get the selected model ID for AI operations
  String? _getSelectedModelId() {
    final selectedModel = ref.read(selectedModelProvider);
    return selectedModel?.id;
  }

  // AI title generation
  Future<void> _generateTitle() async {
    if (_note == null || _isGeneratingTitle) return;
    final content = _contentMarkdown.trim();
    if (content.isEmpty) {
      _showError(AppLocalizations.of(context)!.noContentToGenerateTitle);
      return;
    }

    final modelId = _getSelectedModelId();
    if (modelId == null) {
      _showError(AppLocalizations.of(context)!.noModelSelected);
      return;
    }

    setState(() => _isGeneratingTitle = true);
    ConduitHaptics.lightImpact();

    final api = ref.read(apiServiceProvider);
    if (api == null) {
      setState(() => _isGeneratingTitle = false);
      return;
    }

    try {
      final generatedTitle = await api.generateNoteTitle(
        content,
        modelId: modelId,
      );
      if (mounted && generatedTitle != null && generatedTitle.isNotEmpty) {
        _titleController.text = generatedTitle;
        ConduitHaptics.mediumImpact();
      }
    } catch (e) {
      if (mounted) {
        _showError(AppLocalizations.of(context)!.failedToGenerateTitle);
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
    final content = _contentMarkdown.trim();
    if (content.isEmpty) {
      _showError(AppLocalizations.of(context)!.noContentToEnhance);
      return;
    }

    final modelId = _getSelectedModelId();
    if (modelId == null) {
      _showError(AppLocalizations.of(context)!.noModelSelected);
      return;
    }

    setState(() => _isEnhancing = true);
    ConduitHaptics.lightImpact();

    final api = ref.read(apiServiceProvider);
    if (api == null) {
      setState(() => _isEnhancing = false);
      return;
    }

    try {
      final enhancedContent = await api.enhanceNoteContent(
        content,
        modelId: modelId,
      );
      if (mounted && enhancedContent != null && enhancedContent.isNotEmpty) {
        setState(() {
          _installContentDocument(documentFromMarkdown(enhancedContent));
        });
        // _installContentDocument deliberately leaves _savedMarkdown untouched,
        // so the enhanced content now differs from the saved baseline; re-run
        // change detection to flag the enhancement for auto-save.
        _onContentChanged();
        ConduitHaptics.mediumImpact();
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.noteEnhanced,
          type: AdaptiveSnackBarType.success,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      if (mounted) {
        _showError(AppLocalizations.of(context)!.failedToEnhanceNote);
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
    _voiceService ??= VoiceInputService(api: ref.read(apiServiceProvider));

    try {
      final ok = await _voiceService!.initialize();
      if (!mounted) return;
      if (!ok) {
        _showError(AppLocalizations.of(context)!.voiceInputUnavailable);
        return;
      }

      final stream = await _voiceService!.beginListening();
      if (!mounted) return;

      // Anchor the dictation run at the current selection, or the end of the
      // document when there is no selection. The trailing line-break of a
      // Parchment document is not editable, so clamp before it.
      final controller = _contentController;
      final selection = controller?.selection;
      final docEnd = controller == null
          ? 0
          : (controller.document.length - 1).clamp(
              0,
              controller.document.length,
            );
      _dictationAnchor =
          (selection != null && selection.isValid && !selection.isCollapsed)
          ? selection.start
          : (selection != null && selection.isValid
                ? selection.baseOffset.clamp(0, docEnd)
                : docEnd);
      _dictationLength = 0;

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
    _dictationAnchor = null;
    _dictationLength = 0;
    if (mounted) {
      setState(() => _isRecording = false);
      ConduitHaptics.selectionClick();
    }
  }

  /// Applies the latest (cumulative) dictation [transcript] by replacing the
  /// previously inserted run at [_dictationAnchor] with the new text, leaving
  /// the rest of the document — and its formatting — untouched.
  void _applyDictationText(String transcript) {
    final controller = _contentController;
    final anchor = _dictationAnchor;
    if (controller == null || anchor == null) return;

    final plain = controller.document.toPlainText();
    final needsLeadingSpace =
        anchor > 0 &&
        anchor <= plain.length &&
        !_whitespacePattern.hasMatch(plain[anchor - 1]);
    final insert = needsLeadingSpace ? ' $transcript' : transcript;

    controller.replaceText(
      anchor,
      _dictationLength,
      insert,
      selection: TextSelection.collapsed(offset: anchor + insert.length),
    );
    _dictationLength = insert.length;
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
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: conduitTheme.buttonPrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppBorderRadius.md),
              ),
              child: Icon(
                Platform.isIOS
                    ? CupertinoIcons.keyboard
                    : Icons.keyboard_voice_rounded,
                color: conduitTheme.buttonPrimary,
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
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppBorderRadius.md),
              ),
              child: Icon(
                Platform.isIOS ? CupertinoIcons.mic_fill : Icons.mic_rounded,
                color: Colors.red,
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
                final staged = await _stageAudioFile(file);
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

  ({String serverId, String accountId})? _noteAudioScope() {
    if (!ref.read(isAuthenticatedProvider2)) return null;
    final api = ref.read(apiServiceProvider);
    if (api == null) return null;

    final userId = ref.read(currentUserProvider2)?.id.trim();
    if (userId == null || userId.isEmpty) return null;

    return (serverId: api.serverConfig.id, accountId: 'user:$userId');
  }

  /// Moves a recorder cache file into account-scoped application support
  /// before any network request. Once this returns, closing the page or losing
  /// connectivity cannot discard the recording.
  Future<bool> _stageAudioFile(File audioFile) async {
    final note = _note;
    final scope = _noteAudioScope();
    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);
    final authEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    if (note == null || scope == null) {
      _showError(AppLocalizations.of(context)!.failedToUploadAudio);
      return false;
    }

    final fileName = 'recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      final item = await _noteAudioUploadStore.stage(
        source: audioFile,
        serverId: scope.serverId,
        accountId: scope.accountId,
        noteId: note.id,
        fileName: fileName,
      );
      if (!mounted ||
          !_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
        return true;
      }
      setState(() {
        _pendingAudioMutationGeneration++;
        _hiddenAudioUploadIds.remove(item.id);
        final index = _pendingAudioUploads.indexWhere(
          (candidate) => candidate.id == item.id,
        );
        if (index < 0) {
          _pendingAudioUploads.add(item);
        } else {
          _pendingAudioUploads[index] = item;
        }
        _pendingAudioUploads.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      });
      unawaited(
        _retryPendingAudioUploads(ids: <String>[item.id], showFeedback: true),
      );
      return true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-audio-stage-failed',
        scope: 'notes/audio',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showError(AppLocalizations.of(context)!.failedToUploadAudio);
      }
      return false;
    }
  }

  Future<void> _loadPendingAudioUploads() async {
    final note = _note;
    final scope = _noteAudioScope();
    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);
    final authEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    if (note == null || scope == null) return;
    final mutationGeneration = _pendingAudioMutationGeneration;

    try {
      final currentIds = <String>{widget.noteId, note.id};
      if (db != null) {
        currentIds.add(await db.notesDao.resolveNoteRemapTarget(widget.noteId));
        currentIds.add(await db.notesDao.resolveNoteRemapTarget(note.id));
      }
      if (!mounted ||
          !_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
        return;
      }

      final accountItems = await _noteAudioUploadStore.loadForAccount(
        serverId: scope.serverId,
        accountId: scope.accountId,
      );
      final exactItems = await Future.wait(
        currentIds.map(
          (noteId) => _noteAudioUploadStore.loadForNote(
            serverId: scope.serverId,
            accountId: scope.accountId,
            noteId: noteId,
          ),
        ),
      );
      if (!mounted ||
          !_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
        return;
      }

      final matchingById = <String, PendingNoteAudioUpload>{};
      for (final batch in exactItems) {
        for (final item in batch) {
          matchingById[item.id] = item;
        }
      }
      for (final item in accountItems) {
        if (currentIds.contains(item.noteId)) {
          matchingById[item.id] = item;
          continue;
        }
        if (db != null) {
          final resolvedId = await db.notesDao.resolveNoteRemapTarget(
            item.noteId,
          );
          if (currentIds.contains(resolvedId)) matchingById[item.id] = item;
        }
      }
      if (!mounted ||
          !_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
        return;
      }

      setState(() {
        final changedWhileLoading =
            mutationGeneration != _pendingAudioMutationGeneration;
        if (changedWhileLoading) {
          // A stage, completion, or removal won the race with this disk scan.
          // Preserve the newer UI state while still merging other recovered
          // recordings, always deduplicated by their durable id.
          for (final existing in _pendingAudioUploads) {
            matchingById[existing.id] = existing;
          }
        }
        for (final hiddenId in _hiddenAudioUploadIds) {
          matchingById.remove(hiddenId);
        }
        _pendingAudioUploads
          ..clear()
          ..addAll(matchingById.values)
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      });
      if (ref.read(connectivityStatusProvider) == ConnectivityStatus.online) {
        unawaited(_retryPendingAudioUploads());
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-audio-recovery-failed',
        scope: 'notes/audio',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _retryPendingAudioUploads({
    Iterable<String>? ids,
    bool showFeedback = false,
  }) async {
    if (!mounted || _noteAudioScope() == null) return;
    final requestedIds = ids ?? _pendingAudioUploads.map((item) => item.id);
    _queuedAudioUploadIds.addAll(requestedIds);
    if (showFeedback) {
      _audioUploadFeedbackIds.addAll(requestedIds);
    }
    if (_isDrainingAudioUploads) return;

    _isDrainingAudioUploads = true;
    setState(() => _isUploadingAudio = true);
    try {
      while (mounted && _queuedAudioUploadIds.isNotEmpty) {
        final id = _queuedAudioUploadIds.first;
        _queuedAudioUploadIds.remove(id);
        final showItemFeedback = _audioUploadFeedbackIds.remove(id);
        await _processPendingAudioUpload(id, showFeedback: showItemFeedback);
      }
    } finally {
      _isDrainingAudioUploads = false;
      if (mounted) setState(() => _isUploadingAudio = false);
    }
  }

  Future<void> _processPendingAudioUpload(
    String id, {
    required bool showFeedback,
  }) async {
    final index = _pendingAudioUploads.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final pendingItem = _pendingAudioUploads[index];
    final removalCompletion = NoteAudioUploadCoordinator.removalCompletion(
      pendingItem,
    );
    if (removalCompletion != null) {
      await removalCompletion;
      if (mounted) await _loadPendingAudioUploads();
      return;
    }

    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);
    if (api == null || _noteAudioScope() == null) return;
    final authEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    final authSnapshot = api.captureAuthSnapshot();
    final cancelToken = CancelToken();
    _activeAudioCancelToken = cancelToken;

    _audioUploadsInFlight.add(id);
    if (mounted) setState(() {});
    try {
      final coordinator = NoteAudioUploadCoordinator(
        store: _noteAudioUploadStore,
        upload: (item, file) async {
          if (!mounted ||
              !_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
            throw StateError('The active note session changed');
          }

          // A prior process may have committed the POST but lost its response.
          // OpenWebUI stores this marker under `meta.data`; reconcile before a
          // retry so that uncertain requests do not create duplicate files.
          if (item.status != NoteAudioUploadStatus.pending &&
              item.serverFileId == null) {
            final targetedFiles = await api.searchFilesForSession(
              query: item.fileName,
              limit: 100,
              authSnapshot: authSnapshot,
              cancelToken: cancelToken,
            );
            final files =
                targetedFiles ??
                await api.getUserFilesForSession(
                  authSnapshot: authSnapshot,
                  cancelToken: cancelToken,
                );
            if (!mounted ||
                !_isCurrentNoteSession(
                  api: api,
                  db: db,
                  authEpoch: authEpoch,
                )) {
              throw StateError('The active note session changed');
            }
            final matches =
                files
                    .where((candidate) {
                      final metadata = candidate.metadata;
                      final nested = metadata?['data'];
                      final marker = nested is Map
                          ? nested['conduit_upload_id']
                          : metadata?['conduit_upload_id'];
                      return marker?.toString() == item.id &&
                          candidate.displayName == item.fileName &&
                          candidate.size == item.fileSize;
                    })
                    .toList(growable: false)
                  ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            if (matches.isNotEmpty) return matches.first.id;
          }

          return api.uploadFile(
            file.path,
            item.fileName,
            contentType: 'audio/mp4',
            metadata: <String, dynamic>{'conduit_upload_id': item.id},
            cancelToken: cancelToken,
            authSnapshot: authSnapshot,
          );
        },
        attach: (item, fileId) => _attachUploadedAudio(
          item,
          fileId,
          api: api,
          db: db,
          authEpoch: authEpoch,
          authSnapshot: authSnapshot,
          cancelToken: cancelToken,
        ),
        onChanged: (item) {
          if (mounted &&
              _isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
            _onPendingAudioChanged(id, item);
          }
        },
      );
      final result = await coordinator.process(pendingItem);
      if (!mounted ||
          !_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
        return;
      }

      // A shared in-flight operation may have been owned by a different
      // editor instance, whose change callback does not target this page.
      _onPendingAudioChanged(id, result);

      if (result == null) {
        ConduitHaptics.mediumImpact();
        if (showFeedback) {
          AdaptiveSnackBar.show(
            context,
            message: AppLocalizations.of(context)!.audioRecordingSaved,
            type: AdaptiveSnackBarType.success,
            duration: const Duration(seconds: 2),
          );
        }
      } else if (showFeedback) {
        _showError(AppLocalizations.of(context)!.failedToUploadAudio);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-audio-coordinator-failed',
        scope: 'notes/audio',
        stackTrace: stackTrace,
        data: {'id': id, 'errorType': error.runtimeType.toString()},
      );
      if (mounted &&
          showFeedback &&
          _isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
        _showError(AppLocalizations.of(context)!.failedToUploadAudio);
      }
    } finally {
      if (identical(_activeAudioCancelToken, cancelToken)) {
        _activeAudioCancelToken = null;
      }
      _audioUploadsInFlight.remove(id);
      if (mounted) setState(() {});
    }
  }

  /// Idempotently appends one attachment using the newest local note row.
  ///
  /// The read, duplicate check, and write share the same note lock as sync, so
  /// an upload finishing from an older editor cannot replace files added by a
  /// concurrent pull or recording.
  Future<Note?> _durableAttachNoteAudioFile(
    AppDatabase db, {
    required String id,
    required Map<String, dynamic> attachment,
    required bool Function() canCommit,
  }) async {
    final resolvedId = await db.notesDao.resolveNoteRemapTarget(id);
    if (!canCommit()) return null;

    final noteLocks = ref.read(noteLocksProvider);
    var noteAvailable = false;
    await noteLocks.runExclusive(resolvedId, () async {
      if (!canCommit()) return;
      final existingRow = await db.notesDao.getNote(resolvedId);
      if (existingRow == null || existingRow.deleted || !canCommit()) return;
      noteAvailable = true;

      final existingData = decodeNoteData(existingRow.data);
      final rawFiles = existingData['files'];
      final files = rawFiles is List
          ? rawFiles
                .whereType<Map>()
                .map((file) => Map<String, dynamic>.from(file))
                .toList(growable: true)
          : <Map<String, dynamic>>[];
      final fileId = attachment['id']?.toString();
      final itemId = attachment['itemId']?.toString();
      final alreadyAttached = files.any(
        (file) =>
            (fileId != null && file['id']?.toString() == fileId) ||
            (itemId != null && file['itemId']?.toString() == itemId),
      );
      if (alreadyAttached || !canCommit()) return;

      await db.notesDao.updateNoteWithOutbox(
        resolvedId,
        data: Value(
          jsonEncode(<String, dynamic>{
            ...existingData,
            'files': <Map<String, dynamic>>[
              ...files,
              Map<String, dynamic>.from(attachment),
            ],
          }),
        ),
        localUpdatedAtNs: DateTime.now().microsecondsSinceEpoch * 1000,
        enqueue: true,
      );
    });
    if (!noteAvailable || !canCommit()) return null;

    final row = await db.notesDao.getNote(resolvedId);
    if (row == null || row.deleted || !canCommit()) return null;
    unawaited(_drainPendingAudioAttachment());
    return Note.fromJson(noteRowToServer(row));
  }

  Future<void> _drainPendingAudioAttachment() async {
    try {
      await ref.read(syncEngineProvider.notifier).drainNow();
    } catch (error) {
      DebugLogger.warning(
        'note-audio-attachment-drain-failed',
        scope: 'notes/audio',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  Future<void> _attachUploadedAudio(
    PendingNoteAudioUpload item,
    String fileId, {
    required Object? api,
    required AppDatabase? db,
    required Object authEpoch,
    required ApiAuthSnapshot authSnapshot,
    required CancelToken cancelToken,
  }) async {
    if (!mounted ||
        !_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
      throw StateError('The active note session changed');
    }
    final note = _note;
    if (note == null) throw StateError('The note is no longer available');

    // Device-local paths never enter NoteData. Only the server attachment
    // descriptor is synced, keyed by the durable upload id for replay dedupe.
    final attachment = <String, dynamic>{
      'type': 'file',
      'file': '',
      'id': fileId,
      'url': fileId,
      'name': item.fileName,
      'collection_name': '',
      'status': 'uploaded',
      'size': item.fileSize,
      'error': '',
      'itemId': item.id,
    };

    Note? updatedNote;
    if (db != null) {
      updatedNote = await _durableAttachNoteAudioFile(
        db,
        id: widget.noteId,
        attachment: attachment,
        canCommit: () =>
            mounted &&
            _isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch),
      );
    } else {
      final currentFiles = note.data.files ?? <Map<String, dynamic>>[];
      final alreadyAttached = currentFiles.any(
        (file) =>
            file['id']?.toString() == fileId ||
            file['itemId']?.toString() == item.id,
      );
      if (alreadyAttached) return;
      final data = _composeUpdatedNoteData(
        files: <Map<String, dynamic>>[...currentFiles, attachment],
        includeContent: false,
      );
      final title = _titleController.text.trim();
      updatedNote = await _persistNoteUpdate(
        api: api,
        db: db,
        title: title.isEmpty ? AppLocalizations.of(context)!.untitled : title,
        data: data,
        authEpoch: authEpoch,
        authSnapshot: authSnapshot,
        cancelToken: cancelToken,
      );
    }
    if (updatedNote == null) {
      throw StateError('The recording could not be attached to the note');
    }
    if (!mounted ||
        !_isCurrentNoteSession(api: api, db: db, authEpoch: authEpoch)) {
      throw StateError('The active note session changed');
    }
    ref.invalidate(noteByIdProvider(widget.noteId));
    if (updatedNote.id != widget.noteId) {
      ref.invalidate(noteByIdProvider(updatedNote.id));
    }
    setState(() => _note = updatedNote);
  }

  void _onPendingAudioChanged(String id, PendingNoteAudioUpload? updated) {
    if (!mounted) return;
    setState(() {
      _pendingAudioMutationGeneration++;
      final index = _pendingAudioUploads.indexWhere((item) => item.id == id);
      if (updated == null) {
        _hiddenAudioUploadIds.add(id);
        if (index >= 0) _pendingAudioUploads.removeAt(index);
      } else if (index >= 0) {
        _hiddenAudioUploadIds.remove(id);
        _pendingAudioUploads[index] = updated;
      } else {
        _hiddenAudioUploadIds.remove(id);
        _pendingAudioUploads.add(updated);
      }
      _pendingAudioUploads.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    });
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
      child: ErrorBoundary(
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
                      MediaQuery.viewPaddingOf(context).top + kTextTabBarHeight,
                ),
              ),
              if (!_isLoading && _note != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + kTextTabBarHeight,
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
                  child: _buildFloatingActionsRow(context),
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
    final maxTitleWidth = resolveConduitAdaptiveLeadingPillWidth(
      context,
      trailingActionCount: 1,
      maxWidth: kConduitAdaptiveToolbarMaxPillWidth,
    );
    final leading = _buildNoteEditorLeading(
      context,
      maxTitleWidth: maxTitleWidth,
    );
    final actions = _buildNoteEditorToolbarActionWidgets(context);
    final overlayStyle = Theme.of(context).appBarTheme.systemOverlayStyle;

    return AdaptiveAppBar(
      useNativeToolbar: false,
      tintColor: tintColor,
      cupertinoNavigationBar: CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        border: null,
        backgroundColor: Colors.transparent,
        automaticBackgroundVisibility: false,
        brightness: Theme.of(context).brightness,
        enableBackgroundFilterBlur: false,
        leading: leading,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
      ),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: Elevation.none,
        scrolledUnderElevation: Elevation.none,
        toolbarHeight: kTextTabBarHeight,
        systemOverlayStyle: overlayStyle,
        centerTitle: false,
        titleSpacing: Spacing.sm,
        leadingWidth: resolveConduitAdaptiveToolbarLeadingWidth(
          pillWidth: maxTitleWidth,
        ),
        leading: leading,
        actions: actions,
      ),
    );
  }

  Widget _buildNoteEditorLeading(
    BuildContext context, {
    required double maxTitleWidth,
  }) {
    return buildConduitAdaptiveToolbarLeadingRow(
      children: [
        ConduitAdaptiveAppBarIconButton(
          icon: Platform.isIOS ? CupertinoIcons.line_horizontal_3 : Icons.menu,
          onPressed: () => ResponsiveDrawerLayout.of(context)?.toggle(),
          iconColor: context.conduitTheme.textPrimary,
        ),
        const SizedBox(width: kConduitAdaptiveToolbarLeadingGap),
        _buildNoteEditorTitlePill(context, maxWidth: maxTitleWidth),
      ],
    );
  }

  List<Widget> _buildNoteEditorToolbarActionWidgets(BuildContext context) {
    return buildConduitAdaptiveToolbarActionWidgets([
      _NoteEditorToolbarPopupButton(
        l10n: AppLocalizations.of(context)!,
        isPinned: _note?.isPinned == true,
        tintColor: context.conduitTheme.textPrimary,
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
    final titleTextStyle = conduitAdaptiveToolbarPillTextStyle(context);
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
      onPressed: _isGeneratingTitle
          ? null
          : () => _titleFocusNode.requestFocus(),
      semanticLabel: titleLabel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
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
    return Container(
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
    // App bar height: kTextTabBarHeight + metadata bar (~40)
    final appBarHeight = kTextTabBarHeight + 40;

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
              if (files.isNotEmpty || _pendingAudioUploads.isNotEmpty) ...[
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
    final total = files.length + _pendingAudioUploads.length;

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
        ..._pendingAudioUploads.map(
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
    final inFlight = _audioUploadsInFlight.contains(item.id);
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
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Platform.isIOS ? CupertinoIcons.share : Icons.ios_share,
                    size: IconSize.sm,
                    color: theme.textSecondary,
                  ),
                  tooltip: l10n.shareSystemSheet,
                  onPressed: inFlight ? null : () => _sharePendingAudio(item),
                ),
                if (retryable)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Platform.isIOS
                          ? CupertinoIcons.arrow_clockwise
                          : Icons.refresh_rounded,
                      size: IconSize.sm,
                      color: theme.buttonPrimary,
                    ),
                    tooltip: l10n.retry,
                    onPressed: () => unawaited(
                      _retryPendingAudioUploads(
                        ids: <String>[item.id],
                        showFeedback: true,
                      ),
                    ),
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
            XFile(item.localPath, mimeType: 'audio/mp4', name: item.fileName),
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
    if (_hasChanges) {
      _saveDebounce?.cancel();
      await _autoSave();
    }
    if (!mounted) return;

    // Push local changes and pull remote ones so the local row reflects both
    // sides. Mirrors the notes-list pull-to-refresh.
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    try {
      await ref
          .read(syncEngineProvider.notifier)
          .requestPull(reason: 'note-editor-refresh');
    } catch (_) {
      // Best-effort; still reload from the (at least locally-current) row below.
    }
    if (!mounted) return;

    // Re-read from the reconciled LOCAL row, not a fresh server fetch: the pull
    // has already merged remote edits into it, and reading the row avoids a
    // server copy that's behind a not-yet-pushed local edit clobbering it.
    try {
      // The note is already open in the current session, so an id-scoped read is
      // safe here (avoids pulling auth providers into the editor just for the
      // user id).
      final note = await readLocalNote(db, widget.noteId);
      if (!mounted || note == null) return;
      // If the user typed while the sync/read was in flight, do NOT overwrite
      // their in-progress edits: those keystroke(s) re-set `_hasChanges` and
      // queued a fresh debounce. Bail out and leave the editor as-is so that
      // debounce saves them — overwriting here would discard them silently.
      // (No await between this check and the setState below, so nothing can
      // sneak in.)
      if (_hasChanges) return;
      // Keep the detail cache consistent with what we just loaded.
      ref.invalidate(noteByIdProvider(widget.noteId));
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

    final editor = DrawerOpenGestureExclusion(
      child: FleatherEditor(
        controller: controller,
        focusNode: _contentFocusNode,
        // Lives inside the page's SingleChildScrollView; the editor must not
        // scroll independently so the whole note grows with the content.
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
    final theme = context.conduitTheme;
    final base = AppTypography.bodyLargeStyle.copyWith(
      color: theme.textPrimary,
      height: 1.8,
    );
    final fallback = FleatherThemeData.fallback(context);
    return fallback.copyWith(
      paragraph: TextBlockTheme(
        style: base,
        spacing: const VerticalSpacing(top: 0, bottom: 6),
      ),
      bold: const TextStyle(fontWeight: FontWeight.bold),
      italic: const TextStyle(fontStyle: FontStyle.italic),
      link: TextStyle(
        color: theme.buttonPrimary,
        decoration: TextDecoration.underline,
      ),
    );
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
      if (_audioUploadsInFlight.contains(localUploadId)) return;
      final index = _pendingAudioUploads.indexWhere(
        (item) => item.id == localUploadId,
      );
      if (index < 0) return;
      final item = _pendingAudioUploads[index];
      // Once the server owns the bytes, deleting only this local retry record
      // would misleadingly leave a private orphan on the server. Keep it
      // available for the idempotent attach retry instead.
      if (item.serverFileId != null) return;
      if (!NoteAudioUploadCoordinator.tryReserveRemoval(item)) return;
      _queuedAudioUploadIds.remove(localUploadId);
      _audioUploadFeedbackIds.remove(localUploadId);
      _audioUploadsInFlight.add(localUploadId);
      _hiddenAudioUploadIds.add(localUploadId);
      _pendingAudioMutationGeneration++;
      if (mounted) setState(() {});
      try {
        await _noteAudioUploadStore.remove(item);
        _onPendingAudioChanged(localUploadId, null);
        if (mounted) {
          ConduitHaptics.lightImpact();
          AdaptiveSnackBar.show(
            context,
            message: l10n.fileRemoved,
            type: AdaptiveSnackBarType.success,
            duration: const Duration(seconds: 2),
          );
        }
      } catch (error, stackTrace) {
        DebugLogger.error(
          'note-audio-remove-failed',
          scope: 'notes/audio',
          error: error,
          stackTrace: stackTrace,
          data: {'id': localUploadId},
        );
        _hiddenAudioUploadIds.remove(localUploadId);
        _showError(l10n.errorMessage);
      } finally {
        NoteAudioUploadCoordinator.releaseRemoval(item);
        _audioUploadsInFlight.remove(localUploadId);
        if (mounted) setState(() {});
      }
      return;
    }

    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);
    if (api == null && db == null) return;

    setState(() => _isSaving = true);

    try {
      final fileId = file['id']?.toString();
      final currentFiles = _note!.data.files ?? [];
      final updatedFiles = currentFiles
          .where((f) => f['id']?.toString() != fileId)
          .toList();

      final data = _composeUpdatedNoteData(
        files: updatedFiles,
        includeContent: false,
      );

      final resolvedTitle = _titleController.text.isEmpty
          ? l10n.untitled
          : _titleController.text;
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

  Widget _buildFloatingActionsRow(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Voice/Recording button - shows menu if not recording, stops if recording
        _buildFloatingButton(
          context,
          icon: _isRecording
              ? (Platform.isIOS ? CupertinoIcons.stop_fill : Icons.stop_rounded)
              : (Platform.isIOS ? CupertinoIcons.mic_fill : Icons.mic_rounded),
          color: _isRecording ? theme.error : null,
          isLoading: _isUploadingAudio,
          tooltip: _isRecording ? l10n.stopRecording : l10n.voiceOptions,
          onPressed: _isUploadingAudio
              ? null
              : (_isRecording ? _toggleDictation : _showRecordingOptions),
        ),

        // AI button
        _buildFloatingButton(
          context,
          icon: Platform.isIOS
              ? CupertinoIcons.sparkles
              : Icons.auto_awesome_rounded,
          isLoading: _isEnhancing,
          tooltip: l10n.enhanceWithAI,
          onPressed: _isEnhancing ? null : _enhanceContent,
          showMenu: true,
        ),
      ],
    );
  }

  Widget _buildFloatingButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool isLoading = false,
    Color? color,
    bool showMenu = false,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final button = _buildAdaptiveFloatingButton(
      context,
      icon: icon,
      onPressed: onPressed,
      isLoading: isLoading,
      color: color,
    );

    if (showMenu) {
      return AdaptiveTooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          child: AdaptivePopupMenuButton.widget<String>(
            items: [
              AdaptivePopupMenuItem<String>(
                label: l10n.enhanceNote,
                value: 'enhance',
                icon: Platform.isIOS
                    ? 'wand.and.stars'
                    : Icons.auto_fix_high_rounded,
              ),
              AdaptivePopupMenuItem<String>(
                label: l10n.generateTitle,
                value: 'title',
                icon: Platform.isIOS ? 'textformat' : Icons.title_rounded,
              ),
            ],
            onSelected: (_, entry) {
              switch (entry.value) {
                case 'enhance':
                  _enhanceContent();
                case 'title':
                  _generateTitle();
              }
            },
            buttonStyle: conduitSupportsNativeGlass()
                ? PopupButtonStyle.glass
                : PopupButtonStyle.plain,
            child: IgnorePointer(child: button),
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: tooltip,
      enabled: onPressed != null,
      child: AdaptiveTooltip(message: tooltip, child: button),
    );
  }

  Widget _buildAdaptiveFloatingButton(
    BuildContext context, {
    required IconData icon,
    required VoidCallback? onPressed,
    required bool isLoading,
    Color? color,
  }) {
    final theme = context.conduitTheme;
    final labelColor = theme.textPrimary;
    final borderRadius = BorderRadius.circular(AppBorderRadius.floatingButton);
    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();
    final effectiveColor = usesOpaqueFallback && color == null
        ? theme.surfaceContainerHighest
        : color;

    return AdaptiveButton.child(
      onPressed: onPressed,
      enabled: onPressed != null,
      color: effectiveColor,
      style: usesOpaqueFallback
          ? AdaptiveButtonStyle.filled
          : color == null
          ? AdaptiveButtonStyle.glass
          : AdaptiveButtonStyle.prominentGlass,
      size: AdaptiveButtonSize.large,
      minSize: const Size(TouchTarget.button, TouchTarget.button),
      padding: EdgeInsets.zero,
      borderRadius: borderRadius,
      useSmoothRectangleBorder: false,
      child: SizedBox(
        width: TouchTarget.button,
        height: TouchTarget.button,
        child: Center(
          child: isLoading
              ? SizedBox(
                  width: IconSize.md,
                  height: IconSize.md,
                  child: CircularProgressIndicator(
                    strokeWidth: BorderWidth.medium,
                    valueColor: AlwaysStoppedAnimation(labelColor),
                  ),
                )
              : Icon(
                  icon,
                  color: color == null ? labelColor : Colors.white,
                  size: IconSize.lg,
                ),
        ),
      ),
    );
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
                color: sidebarTheme.accent.withValues(alpha: 0.5),
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
              onPressed: () => Navigator.of(context).pop(),
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

class _NoteEditorToolbarPopupButton extends StatelessWidget {
  const _NoteEditorToolbarPopupButton({
    required this.l10n,
    required this.isPinned,
    required this.tintColor,
    required this.onSelected,
  });

  final AppLocalizations l10n;
  final bool isPinned;
  final Color tintColor;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return ConduitAdaptiveToolbarOverflowButton<String>(
      tintColor: tintColor,
      items: [
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
          label: isPinned ? l10n.unpin : l10n.pin,
          icon: conduitAdaptivePopupMenuIcon(
            iosSymbol: isPinned ? 'pin.slash' : 'pin',
            materialIcon: isPinned
                ? Icons.push_pin_outlined
                : Icons.push_pin_outlined,
          ),
        ),
        AdaptivePopupMenuItem<String>(
          value: 'delete',
          label: l10n.delete,
          icon: conduitAdaptivePopupMenuIcon(
            iosSymbol: 'trash',
            materialIcon: Icons.delete_outline,
          ),
        ),
      ],
      onSelected: onSelected,
    );
  }
}
