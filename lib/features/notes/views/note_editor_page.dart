import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';

import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:io' show File, Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';

import 'package:conduit_core/database/app_database.dart';

import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';

import 'package:conduit_core/models/note.dart';

import 'package:conduit_core/providers/app_providers.dart';

import '../../../core/services/ios_native_dropdown_bridge.dart';

import 'package:conduit_core/sync/sync_engine.dart';

import 'package:conduit_core/features/notes/services/deleted_note_draft_recovery.dart';
import 'package:conduit_core/features/notes/services/note_ai_actions.dart';
import 'package:conduit_core/features/notes/services/note_attachments_controller.dart';
import 'package:conduit_core/features/notes/services/note_dictation.dart';
import 'package:conduit_core/features/notes/utils/note_access.dart';
import 'package:conduit_core/features/notes/utils/note_file_cards.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:conduit_core/features/sharing/providers/principal_lookup.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart'
    show WorkspacePrincipalType;
import 'package:conduit_core/features/notes/utils/note_persistence.dart';

import '../utils/note_context_actions.dart';
import '../utils/note_file_download.dart';
import '../utils/note_file_link_insertion.dart';
import '../widgets/note_pages_sheet.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/services/navigation_service.dart';
import '../../navigation/utils/sidebar_page_back.dart';
import '../../navigation/widgets/sidebar_page_leading_button.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/utils/file_type_utils.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/horizontal_gesture_ownership.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/themed_sheets.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import '../../chat/services/voice_input_service.dart';
import '../providers/notes_providers.dart';
import '../services/note_audio_upload_service.dart';
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

  // The session the page opened under. A retained provider can rebuild for
  // another account while this page is alive, so loads, saves and destructive
  // actions are judged against these rather than against whatever is current
  // when they run.
  late final Object? _openApi;
  late final AppDatabase? _openDb;
  late final Object _openAuthEpoch;
  late final String? _openUserId;

  /// A save was refused because edit access is gone. The typed text stays in
  /// the editor, which turns read-only, until the user saves it as their own
  /// note or discards it.
  bool _writeRefused = false;

  /// Whether dictation is starting: listening is not running yet, but will
  /// write into the page shown.
  bool _dictationStarting = false;

  /// Whether a file is being removed from the page shown, whose text loses
  /// its link once the stored note has.
  bool _removingFile = false;

  /// Whether the draft is being saved as a note of its own.
  bool _savingAsOwnNote = false;

  /// Counts dictation ends: a start under way when one ends does not begin.
  int _dictationEnds = 0;

  /// The server refused to show the note (403), which is not a missing note.
  bool _loadForbidden = false;

  /// The owner of a note shared read-only with this account, looked up by id
  /// when the note itself does not name them. [_ownerLookupFor] is the owner
  /// id asked about, so each owner is looked up once.
  String? _ownerLookupFor;
  String? _resolvedOwnerName;

  /// The account changed after the page opened, so nothing it loads or saves
  /// belongs to the page any more.
  bool _sessionChanged = false;

  late final ProviderContainer _container;
  late final NoteAttachmentsController _attachments;
  late final DeletedNoteDraftRecovery _recovery;

  // Voice input
  VoiceInputService? _voiceService;
  StreamSubscription<String>? _voiceSub;
  // The in-progress dictation run: each (cumulative) transcript update
  // replaces the previous one without disturbing the rest of the document.
  NoteDictationRun? _dictationRun;
  // The listening run this editor started. The voice service is shared with
  // the chat composer and holds one run at a time, so the editor stops it only
  // while its own run is still the current one. Compared with `==`: reading a
  // controller's `stream` twice gives two wrappers that are equal (same
  // controller) but not identical, and each run has its own controller.
  Stream<String>? _dictationStream;

  // Markdown snapshot of the last saved/loaded document, used to detect real
  // edits. Compared against the re-encoded current document so opening a note
  // never registers as a spurious change from non-semantic markdown
  // normalisation.
  String _savedMarkdown = '';

  /// The stored markdown of the page the editor shows, as last loaded or
  /// saved. A file link the stored page gains beyond it (a recording attached,
  /// or files a sync moved into the content on an Open WebUI 0.12.5 server)
  /// is merged into the next save and put in the editor; a link the user
  /// removed since stays removed.
  String _linkBase = '';

  /// The page the editor shows and saves to. Open WebUI 0.12.5 notes can have
  /// several; every other note has only its main page.
  String _pageId = kNoteMainPageId;

  /// The page the editor shows was removed elsewhere while it held unsaved
  /// text: nothing more is saved to it, and the text can be kept as a note
  /// of its own or discarded.
  bool _pageMissing = false;

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
    return controller == null
        ? ''
        : noteMarkdownFromDocument(controller.document);
  }

  void _updateWordCount() {
    final text = _countedText.trim();
    _cachedWordCount = text.isEmpty ? 0 : text.split(_whitespacePattern).length;
  }

  int get _charCount => _countedText.length;

  /// The text counted for words and characters: file cards are not text.
  String get _countedText => _contentPlainText.replaceAll(
    EmbedNode.kObjectReplacementCharacter,
    '',
  );

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _openApi = ref.read(apiServiceProvider);
    _openDb = ref.read(appDatabaseProvider);
    _openAuthEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    _openUserId = ref.read(currentUserProvider2)?.id;
    _attachments = NoteAttachmentsController(
      container: _container,
      store: createNoteAudioUploadStore(),
      noteId: widget.noteId,
      currentNote: () => _note,
      resolvedTitle: _resolvedTitle,
      onNoteUpdated: (note) {
        if (!mounted) return;
        setState(() {
          _takeStoredNote(note);
          _showFileLinksOf(note);
        });
      },
      onChanged: () {
        if (mounted) setState(() {});
      },
      onNotice: _onAudioNotice,
      currentPageId: () => _pageId,
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
              _pageId = kNoteMainPageId;
              _pageMissing = false;
              _linkBase = _pageMarkdown(note);
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

  /// Whether the editor is in view. Leaving it for the notes list or another
  /// page keeps it mounted out of sight, with its tickers muted.
  bool _inView = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fleatherTheme = _buildFleatherTheme(context);
    final inView = TickerMode.valuesOf(context).enabled;
    if (_inView && !inView) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_inView) unawaited(_endDictationOutOfView());
      });
    }
    _inView = inView;
  }

  /// Dictation writes into the text in view, so it ends once the editor is
  /// out of sight, and what it wrote is saved.
  Future<void> _endDictationOutOfView() async {
    if (!_isRecording && !_dictationStarting) return;
    // A start still under way is called off too.
    _dictationEnds++;
    if (_isRecording) await _stopDictation();
    if (!mounted) return;
    _saveDebounce?.cancel();
    await _autoSave();
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
    if (_isRecording && _ownsDictationRun) _voiceService?.stopListening();
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

  /// Whether the page is still in the session it opened under. Unlike
  /// [_isCurrentNoteSession] it takes nothing from the moment of the call, so
  /// an account switched in between cannot pass for the one that opened it.
  bool get _isOpenSessionCurrent => _isCurrentNoteSession(
    api: _openApi,
    db: _openDb,
    authEpoch: _openAuthEpoch,
  );

  /// Editing is off unless the note is known to be writable by the account
  /// that opened it, or a save was refused.
  bool get _readOnly =>
      _writeRefused ||
      _pageMissing ||
      _note == null ||
      noteWriteAccess(_note!, accountId: _openUserId) !=
          NoteWriteAccess.allowed;

  /// The stored markdown of the page the editor shows ([_pageId]). A note in
  /// the older shape, or with one page, has its content.
  String _pageMarkdown(Note note) {
    if (note.isMultiPage) {
      final pageId = _hasPage(note, _pageId) ? _pageId : kNoteMainPageId;
      for (final page in note.data.pages) {
        if (page.id == pageId) return page.content.md;
      }
    }
    return note.markdownContent;
  }

  /// Whether [note] has page [pageId]; the main page is always there.
  bool _hasPage(Note note, String pageId) =>
      pageId == kNoteMainPageId ||
      (note.isMultiPage && note.data.pages.any((page) => page.id == pageId));

  /// Keeps [_pageId] on a page [note] has: the main page when the note has
  /// one page, or when the page shown was removed elsewhere, which returns
  /// whether it was.
  bool _settlePage(Note note) {
    if (_hasPage(note, _pageId)) return false;
    _pageId = kNoteMainPageId;
    _pageMissing = false;
    return true;
  }

  /// Takes in [note], read back from storage after a save or an attachment:
  /// the page shown may have been removed by a sync meanwhile. Without unsaved
  /// text the editor moves to the main page; with it the text stays, marked
  /// as belonging to no page.
  void _takeStoredNote(Note note) {
    _note = note;
    if (_hasPage(note, _pageId)) return;
    if (_contentMarkdown != _savedMarkdown) {
      _pageMissing = true;
      _hasChanges = true;
      // The text is kept as it is; dictation would go on changing it.
      _dropDictation();
      return;
    }
    _settlePage(note);
    _dropDictation();
    _installContentDocument(noteDocumentFromMarkdown(_pageMarkdown(note)));
    _savedMarkdown = _contentMarkdown;
    _linkBase = _pageMarkdown(note);
    // The title belongs to the note, not the page: one typed meanwhile is
    // still to be saved.
    _hasChanges = _resolvedTitle() != note.title;
    _updateWordCount();
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        AdaptiveSnackBar.show(
          context,
          message: l10n.notePageRemoved,
          type: AdaptiveSnackBarType.info,
        );
      });
    }
  }

  /// Puts a card for each file the stored [note] gained on the page shown
  /// beyond [_linkBase] (Open WebUI 0.12.5 keeps attachments as links in the
  /// page content) into the editor, unless it shows the file already: at the
  /// cursor while the user is writing, else at the end. Then moves
  /// [_linkBase] on to [note].
  void _showFileLinksOf(Note note) {
    if (!_hasPage(note, _pageId)) return;
    final stored = _pageMarkdown(note);
    final base = _linkBase;
    _linkBase = stored;
    final controller = _contentController;
    if (controller == null || _readOnly) return;
    final known = <String>{
      for (final link in noteFileLinksInMarkdown(base)) link.id,
      for (final link in noteFileLinksInMarkdown(_contentMarkdown)) link.id,
    };
    final gained = [
      for (final link in noteFileLinksInMarkdown(stored))
        if (!known.contains(link.id)) link,
    ];
    if (gained.isEmpty) return;
    // Text typed while a save ran is not saved yet; the debounce it started
    // still compares against [_savedMarkdown] and saves it.
    final wasSaved = _contentMarkdown == _savedMarkdown;
    final index = _cardInsertIndex();
    insertNoteFileCardsInEditor(controller, gained, index: index);
    if (wasSaved && index == null) {
      // The stored note already holds these files, at the end of the page as
      // here: nothing new to save. Cards put in at the cursor sit elsewhere
      // than the stored links, so that place is saved.
      _savedMarkdown = _contentMarkdown;
    }
  }

  /// Where a file card goes in: at the cursor while the user writes in a
  /// plain paragraph, else at the end. In a list, quote or code block a link
  /// is no attachment, so the card would be read back as a plain link. While
  /// dictation runs, at the end, where it cannot move the text dictation is
  /// rewriting.
  int? _cardInsertIndex() {
    final controller = _contentController;
    if (controller == null || !_contentFocusNode.hasFocus) return null;
    if (_isRecording || _dictationRun != null) return null;
    final selection = controller.selection;
    if (!selection.isValid) return null;
    final line = controller.document.lookupLine(selection.extentOffset).node;
    if (line is! LineNode || line.parent is BlockNode) return null;
    if (line.style.lineAttributes.isNotEmpty) return null;
    return selection.extentOffset;
  }

  /// Saves the page shown, then shows page [pageId] of the note, as stored
  /// now. An edit that could not be saved keeps the editor on its page, as
  /// does a running enhancement, whose result belongs to this page; dictation
  /// stops, since it writes into this page's text.
  Future<void> _showPage(String pageId) async {
    if (pageId == _pageId ||
        _note == null ||
        _isEnhancing ||
        _dictationStarting ||
        _removingFile ||
        _savingAsOwnNote) {
      return;
    }
    if (_isRecording) await _stopDictation();
    if (!mounted) return;
    _saveDebounce?.cancel();
    await _autoSave();
    // A title or text the save left unsaved, or refused, keeps the editor
    // here with its recovery choices; once the draft is discarded, the
    // note's pages can be read.
    bool unsaved() =>
        _contentMarkdown != _savedMarkdown || _hasChanges || _pageMissing;
    if (!mounted || unsaved() || _isEnhancing) return;
    // A sync may have brought newer pages since this editor last read them.
    final stored = await _readStoredNote();
    // An enhancement or dictation started meanwhile works on this page.
    if (!mounted ||
        unsaved() ||
        _isEnhancing ||
        _isRecording ||
        _dictationStarting ||
        _removingFile) {
      return;
    }
    final note = stored ?? _note!;
    // A sync may have renamed the note; the old title would be saved over the
    // new one with the next edit.
    if (_titleController.text != note.title) {
      _titleController.text = note.title;
    }
    setState(() {
      _note = note;
      _pageId = pageId;
      _settlePage(note);
      _installContentDocument(noteDocumentFromMarkdown(_pageMarkdown(note)));
      _savedMarkdown = _contentMarkdown;
      _linkBase = _pageMarkdown(note);
      _hasChanges = false;
      _updateWordCount();
    });
    // Taking the stored title is no edit to save.
    _saveDebounce?.cancel();
  }

  /// The note as stored now, or null without a database (or a stored copy).
  Future<Note?> _readStoredNote() async {
    final db = _openDb;
    final id = _note?.id;
    if (db == null || id == null || !_isOpenSessionCurrent) return null;
    final row = await db.notesDao.getNote(id);
    if (row == null || row.deleted || !_isOpenSessionCurrent) return null;
    return Note.fromJson(noteRowToServer(row));
  }

  Future<void> _openPagesSheet() async {
    final note = _note;
    if (note == null || !note.isMultiPage || _isEnhancing) return;
    final picked = await showNotePagesSheet(
      context,
      entries: notePageEntries(note.data.pages, _resolvedTitle()),
      currentId: _pageId,
    );
    if (picked == null || !mounted) return;
    await _showPage(picked);
  }

  /// The path of the page shown, as the Pages sheet names it.
  String _pagePath(Note note) {
    for (final entry in notePageEntries(note.data.pages, _resolvedTitle())) {
      if (entry.id == _pageId) return entry.path;
    }
    return _resolvedTitle();
  }

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
        // The provider may have rebuilt for another account while loading; its
        // note is not this page's to show.
        if (!_isOpenSessionCurrent) {
          setState(() {
            _isLoading = false;
            _sessionChanged = true;
          });
          return;
        }
        if (note == null) {
          setState(() => _isLoading = false);
          return;
        }
        setState(() {
          _note = note;
          _titleController.text = note.title;
          _settlePage(note);
          _installContentDocument(noteDocumentFromMarkdown(_pageMarkdown(note)));
          _savedMarkdown = _contentMarkdown;
          _linkBase = _pageMarkdown(note);
          _updateWordCount();
          _isLoading = false;
          _hasChanges = false;
        });
        unawaited(_attachments.loadPending());
      }
    } catch (e) {
      if (mounted) {
        // A refusal is not a deleted note: say so, and show nothing else.
        if (e is DioException && e.response?.statusCode == 403) {
          setState(() {
            _isLoading = false;
            _loadForbidden = true;
          });
          return;
        }
        setState(() => _isLoading = false);
        _showError(e.toString());
      }
    }
  }

  Future<Note?> _readNoteById(String noteId) {
    final provider = noteByIdProvider(noteId);
    // An invalidated provider keeps its previous value or error while it
    // recomputes (e.g. right after this note was saved), so only a state that
    // is no longer loading is the result for this opening.
    final current = ref.read(provider);
    if (!current.isLoading) {
      if (current.hasValue) {
        return Future<Note?>.value(current.value);
      }
      if (current.hasError) {
        return Future<Note?>.error(
          current.error ?? StateError('Failed to load note'),
        );
      }
    }

    final completer = Completer<Note?>();
    ProviderSubscription<AsyncValue<Note?>>? subscription;

    void completeFromState(AsyncValue<Note?> state) {
      if (completer.isCompleted || state.isLoading) return;
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
    if (!mounted || _isLoading || _note == null || _readOnly) return;

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
  /// i.e. there is a pending edit or dictation is running: end dictation and
  /// take its last words, flush the edit while still mounted (so the durable
  /// write doesn't race teardown), then pop programmatically.
  Future<void> _onEditorPopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    // Dictation's last words arrive as it stops, and closing the editor
    // would drop them.
    _dictationEnds++;
    if (_isRecording) await _stopDictation();
    if (!mounted) return;
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

  /// Saves a pending edit before the editor is left by its back button.
  /// Returns false, keeping the editor open, when the save did not land, so a
  /// remotely deleted note's recovery retry stays reachable.
  Future<bool> _saveBeforeLeaving() async {
    // Dictation would keep adding text the saves below chase.
    _dictationEnds++;
    if (_isRecording) await _stopDictation();
    if (!mounted) return false;
    _saveDebounce?.cancel();
    // A save covers the text as it began, so typing while it runs needs
    // another; a few rounds catch up with any typing that is still going.
    for (
      var round = 0;
      round < 3 && (_hasChanges || _hasUnsavedText);
      round++
    ) {
      await _autoSave();
      if (!mounted) return false;
    }
    if (_hasChanges || _hasUnsavedText) {
      _recovery.pendingRetry?.call();
      return false;
    }
    return true;
  }

  /// Whether [_autoSave] has text to save that would change what is stored.
  /// A title differs only when the save would store another one: a stored
  /// title that is empty or padded, as notes made elsewhere can have, is not
  /// an edit.
  bool get _hasUnsavedText {
    final note = _note;
    if (note == null) return false;
    final titleUnsaved =
        _titleController.text != note.title && _resolvedTitle() != note.title;
    return titleUnsaved || _contentMarkdown != _savedMarkdown;
  }

  Future<void> _autoSave() async {
    final note = _note;
    // Text kept from a removed page has nowhere to be saved; it waits for the
    // user to keep it as a note of its own or discard it.
    if (note == null || _pageMissing) return;

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
    Map<String, dynamic> Function(Map<String, dynamic> existing)? dataFrom,
    required String pageId,
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
      dataFrom: dataFrom,
      // The page the text was edited on: on Open WebUI 0.12.5 a note that
      // gained pages meanwhile keeps the text there.
      pageId: pageId,
      authEpoch: authEpoch,
      // The account that opened the page, not whoever is active at Save.
      accountId: _openUserId,
      authSnapshot: authSnapshot,
      cancelToken: cancelToken,
      isStillOpen: () => mounted,
    );
  }

  Future<void> _saveNote({bool showFeedback = true}) async {
    if (_note == null || _readOnly) return;

    // An account switched since the page opened must not receive this edit,
    // and the text stays where it is rather than being retried under it.
    if (!_isOpenSessionCurrent) {
      _saveDebounce?.cancel();
      setState(() => _sessionChanged = true);
      _showError(AppLocalizations.of(context)!.noteSessionChangedNotice);
      return;
    }

    setState(() => _isSaving = true);

    final api = _openApi;
    final db = _openDb;
    if (api == null && db == null) {
      setState(() => _isSaving = false);
      return;
    }

    final pageId = _pageId;
    try {
      final title = _titleController.text.trim();

      // Preserve existing note data (versions, attached files) — only the
      // content changes here.
      final savedMarkdown = _contentMarkdown;
      final linkBase = _linkBase;
      final data = _composeUpdatedNoteData();

      final resolvedTitle = title.isEmpty
          ? AppLocalizations.of(context)!.untitled
          : title;
      final updatedNote = await _persistNoteUpdate(
        api: api,
        db: db,
        title: resolvedTitle,
        data: data,
        // Read inside the note lock: a file link the stored page gained since
        // this text was loaded is kept, not replaced by the editor's copy.
        dataFrom: (existing) => noteContentData(
          mergeNoteFileLinks(
            base: linkBase,
            stored: notePageMarkdown(existing, pageId),
            mine: savedMarkdown,
          ),
        ),
        pageId: pageId,
        authEpoch: _openAuthEpoch,
      );

      if (mounted) {
        if (!_isOpenSessionCurrent) {
          setState(() {
            _isSaving = false;
            _sessionChanged = true;
          });
          return;
        }

        // A save that ends after the editor moved to another page holds text
        // that page never showed: it is no baseline for it.
        if (pageId != _pageId) {
          setState(() => _isSaving = false);
          return;
        }

        if (updatedNote != null) {
          // A title or text typed while the save ran is not in it: it stays
          // unsaved, so leaving the page saves it first.
          final editedDuringSave =
              _titleController.text.trim() != title ||
              _contentMarkdown != savedMarkdown;
          setState(() {
            _savedMarkdown = savedMarkdown;
            _isSaving = false;
            _hasChanges = editedDuringSave;
            _takeStoredNote(updatedNote);
            _showFileLinksOf(updatedNote);
          });

          if (showFeedback) {
            ConduitHaptics.lightImpact();
          }
        } else {
          setState(() => _isSaving = false);
        }
      }
    } on NoteWriteDeniedException {
      // Access went away since the note loaded. Keep the draft on screen,
      // stop autosaving it, and leave the choice to the user.
      _saveDebounce?.cancel();
      if (mounted) {
        setState(() {
          _isSaving = false;
          _writeRefused = true;
        });
      }
    } on NotePageMissingException {
      // A sync removed the page this text was written on. Keep the text and
      // let the user keep it as a note of its own; the note as stored now is
      // what Discard goes back to.
      // The page is only switched once its text is saved, so a refusal that
      // ends after a switch holds nothing to keep.
      if (pageId != _pageId) {
        if (mounted) setState(() => _isSaving = false);
        return;
      }
      _saveDebounce?.cancel();
      final stored = await _readStoredNote();
      if (!mounted) return;
      // A switch can also finish while the note is read back: the refusal is
      // then about the page left, and changes nothing on the one shown.
      if (pageId != _pageId) {
        setState(() => _isSaving = false);
        return;
      }
      setState(() {
        _isSaving = false;
        if (stored != null && !_hasPage(stored, _pageId)) {
          // As for a page removed under the editor: text that differs from
          // what was saved stays, to keep or discard; text the user put back
          // meanwhile leaves nothing to keep, and the main page shows.
          _takeStoredNote(stored);
        } else {
          // The stored note could not be read back: the text stays, with the
          // choices to keep it or discard it.
          _pageMissing = true;
          _hasChanges = true;
          // The text is kept as it is; dictation would go on changing it.
          _dropDictation();
          if (stored != null) _note = stored;
        }
      });
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

    // The dialog outlives the tap; an account switched while it was open must
    // not delete the note under another identity.
    if (confirmed && mounted && _isOpenSessionCurrent) {
      ConduitHaptics.mediumImpact();
      final route = NavigationService.currentRoute;
      final routeRevision = NavigationService.currentRouteRevision;
      final success = await ref
          .read(noteDeleterProvider.notifier)
          .deleteNote(note.id);
      // Back no longer returns to the deleted note, wherever the user is, by
      // either id: a note made offline keeps the one it opened with in its
      // location once it carries its server id.
      if (success) {
        for (final id in {widget.noteId, note.id}) {
          NavigationService.forgetPath('/notes/$id');
        }
      }
      if (success &&
          mounted &&
          _isOpenSessionCurrent &&
          NavigationService.currentRoute == route &&
          NavigationService.currentRouteRevision == routeRevision) {
        context.go('/chat');
      }
    }
  }

  /// Opens the note's access sheet. The editor's own opening session must
  /// still be the active one; the sheet then captures the same session again
  /// for the share operation itself.
  Future<void> _shareNote() async {
    final note = _note;
    if (note == null || _readOnly) return;
    if (!_isOpenSessionCurrent) {
      _showError(AppLocalizations.of(context)!.noteSessionChangedNotice);
      return;
    }
    final saved = await shareNote(context, ref, note);
    if (saved == null || !mounted || !_isOpenSessionCurrent) return;
    // The server's answer carries the account's write access, which a save can
    // change; the editor follows it.
    setState(() {
      _note = _note?.copyWith(
        writeAccess: saved.writeAccess ?? _note?.writeAccess,
        accessGrants: saved.rawGrants,
      );
    });
  }

  Future<void> _togglePin() async {
    final note = _note;
    if (note == null || !_isOpenSessionCurrent) {
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
    if (_note == null || _isGeneratingTitle || _readOnly) return;
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
    if (_note == null || _isEnhancing || _readOnly) return;
    final l10n = AppLocalizations.of(context)!;

    setState(() => _isEnhancing = true);
    ConduitHaptics.lightImpact();
    try {
      final enhancedPage = _pageId;
      final result = await enhanceNote(_container, _contentMarkdown);
      // The result belongs to the page it was made from.
      if (!mounted || _pageId != enhancedPage || _pageMissing) return;
      switch (result.outcome) {
        case NoteAiOutcome.done:
          // On Open WebUI 0.12.5 files are attached by links in the text; one
          // the model left out is put back, as enhancing detaches nothing.
          final before = noteFileLinksInMarkdown(_contentMarkdown);
          final enhanced = appendNoteFileLinks(result.text!, [
            for (final link in before) link.toAttachment(),
          ]);
          setState(() {
            _installContentDocument(noteDocumentFromMarkdown(enhanced));
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
    if (_readOnly || _dictationStarting) return;
    // Use the shared service, as the chat composer does, so dictation honours
    // the user's speech-to-text preference (e.g. server-only) and locale.
    _voiceService ??= ref.read(voiceInputServiceProvider);
    // Dictation writes into the page it was started on: the editor stays on
    // it while listening starts ([_showPage] waits for this).
    final page = _pageId;
    final ends = _dictationEnds;
    _dictationStarting = true;

    try {
      final ok = await _voiceService!.initialize();
      if (!mounted || _readOnly || ends != _dictationEnds) return;
      if (!ok) {
        _showError(AppLocalizations.of(context)!.voiceInputUnavailable);
        return;
      }

      final stream = await _voiceService!.beginListening();
      if (!mounted ||
          _pageId != page ||
          _readOnly ||
          ends != _dictationEnds) {
        // The editor closed, shows another page, or can no longer be edited
        // (a sync removed the page, say) while listening was starting.
        // Capture is already running and nothing else will stop it, so stop
        // it here, unless another consumer has taken the service over since.
        if (_voiceService?.textStream == stream) {
          unawaited(_voiceService?.stopListening());
        }
        return;
      }
      _dictationStream = stream;

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
        // A run that ends by itself is over too: a card that comes in later
        // goes in at the cursor again.
        onDone: () {
          if (!mounted) return;
          _dictationStream = null;
          _dictationRun = null;
          setState(() => _isRecording = false);
        },
        onError: (_) {
          if (!mounted) return;
          _dictationStream = null;
          _dictationRun = null;
          setState(() => _isRecording = false);
        },
      );
    } catch (e) {
      _showError(AppLocalizations.of(context)!.failedToStartDictation);
      if (mounted) {
        setState(() => _isRecording = false);
      }
    } finally {
      _dictationStarting = false;
    }
  }

  /// Ends dictation at once, for a document about to be replaced: its run
  /// points into the text being taken away. Called inside `setState`.
  void _dropDictation() {
    // A start still under way is called off too.
    _dictationEnds++;
    if (!_isRecording && _dictationRun == null && _dictationStream == null) {
      return;
    }
    final owned = _ownsDictationRun;
    _voiceSub?.cancel();
    _voiceSub = null;
    _dictationStream = null;
    _dictationRun = null;
    _isRecording = false;
    if (owned) unawaited(_voiceService?.stopListening());
  }

  /// Whether the voice service is still on the run this editor started.
  bool get _ownsDictationRun =>
      _dictationStream != null && _voiceService?.textStream == _dictationStream;

  Future<void> _stopDictation() async {
    if (_ownsDictationRun) await _voiceService?.stopListening();
    _voiceSub?.cancel();
    _dictationStream = null;
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
    // The recording belongs to the page shown when it starts: a page switch
    // that finishes while the overlay is open does not move it.
    final recordedOn = _pageId;
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
                final staged = await _attachments.stage(
                  file,
                  pageId: recordedOn,
                );
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
    // The Share action depends on this; watching rebuilds the menu when the
    // account's permissions arrive or change.
    ref.watch(workspaceCapabilitiesProvider);
    // The read-only banner names the note's owner once the account's lookup
    // exists; watching retries the lookup when it arrives.
    ref.watch(workspacePrincipalLookupProvider);
    final notesEnabled = ref.watch(notesFeatureEnabledProvider);
    if (!notesEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // This editor can remain mounted in an inactive navigation branch.
        if (mounted &&
            GoRouter.of(context).routeInformationProvider.value.uri.path ==
                '/notes/${widget.noteId}') {
          context.go('/chat');
        }
      });
      // Show empty scaffold while redirecting
      return const AdaptiveRouteShell(body: SizedBox.shrink());
    }

    final goesBack = sidebarPagesGoBack(ref);
    return PopScope(
      // Allow the back gesture/animation to proceed normally when there is
      // nothing to save. When an edit is still pending (within the auto-save
      // debounce), or dictation is running and has last words to deliver,
      // intercept the pop, flush the save while the widget is still mounted
      // (so the durable write completes without racing teardown), then pop
      // programmatically. The sliding sidebar opens the editor in place, so
      // its back returns to the page before, as the back button does.
      canPop: !_hasChanges && !_isRecording && !goesBack,
      onPopInvokedWithResult: goesBack
          ? (didPop, _) {
              if (didPop) return;
              unawaited(
                goBackFromSidebarPage(
                  fallback: Routes.notes,
                  beforeBack: _saveBeforeLeaving,
                ),
              );
            }
          : _onEditorPopInvoked,
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
            if (!_isLoading &&
                _note != null &&
                !_readOnly &&
                !_contentFocusNode.hasFocus)
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
            if (!_isLoading &&
                _note != null &&
                !_readOnly &&
                _contentFocusNode.hasFocus)
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
      leading: SidebarPageLeadingButton(
        fallback: Routes.notes,
        beforeBack: _saveBeforeLeaving,
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
      if (!_readOnly)
        AdaptivePopupMenuItem<String>(
          value: 'generate',
          label: l10n.generateTitle,
          icon: conduitAdaptivePopupMenuIcon(
            iosSymbol: 'sparkles',
            materialIcon: Icons.auto_awesome,
          ),
        ),
      if (_note?.isMultiPage ?? false)
        AdaptivePopupMenuItem<String>(
          value: 'pages',
          label: l10n.notePages,
          icon: conduitAdaptivePopupMenuIcon(
            iosSymbol: 'doc.on.doc',
            materialIcon: Icons.layers_outlined,
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
      if (_note != null && !_readOnly && canShareNote(ref, _note!))
        AdaptivePopupMenuItem<String>(
          value: 'share',
          label: l10n.noteShare,
          icon: conduitAdaptivePopupMenuIcon(
            iosSymbol: 'person.2',
            materialIcon: Icons.group_outlined,
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
      // The delete endpoint takes the same people as an edit.
      if (!_readOnly)
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
      case 'pages':
        ConduitHaptics.selectionClick();
        unawaited(_openPagesSheet());
        return;
      case 'copy':
        ConduitHaptics.selectionClick();
        _copyToClipboard();
        return;
      case 'pin':
        _togglePin();
        return;
      case 'share':
        ConduitHaptics.selectionClick();
        unawaited(_shareNote());
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
                            child: AdaptiveProgressIndicator(
                              strokeWidth: BorderWidth.medium,
                              color: conduitTheme.loadingIndicator,
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
                                readOnly: _readOnly,
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
                    child: AdaptiveProgressIndicator(
                      strokeWidth: BorderWidth.medium,
                      color: conduitTheme.loadingIndicator,
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
          // The page's path gives way first on a narrow screen.
          if (_note?.isMultiPage ?? false) ...[
            Flexible(child: _buildPageChip(context, _note!)),
            _buildMetadataSeparator(context),
          ],
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

  /// The page shown, by its path, for a note with several pages: tapping it
  /// lists the pages to move to.
  Widget _buildPageChip(BuildContext context, Note note) {
    final l10n = AppLocalizations.of(context)!;
    final secondaryColor = context.conduitTheme.textSecondary;
    final path = _pagePath(note);
    return Semantics(
      button: true,
      label: l10n.notePageChipLabel(path),
      excludeSemantics: true,
      onTap: () => unawaited(_openPagesSheet()),
      child: GestureDetector(
        key: const ValueKey<String>('note-page-chip'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ConduitHaptics.selectionClick();
          unawaited(_openPagesSheet());
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.xs,
            vertical: Spacing.xxs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Platform.isIOS ? CupertinoIcons.doc_on_doc : Icons.layers_outlined,
                color: secondaryColor,
                size: IconSize.xs,
              ),
              const SizedBox(width: Spacing.xxs),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.tiny.copyWith(
                      color: secondaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Icon(
                Platform.isIOS
                    ? CupertinoIcons.chevron_down
                    : Icons.expand_more_rounded,
                color: secondaryColor,
                size: IconSize.xs,
              ),
            ],
          ),
        ),
      ),
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

    // The file list servers before 0.12.5 keep, and the files the page links
    // where no card shows them: 0.12.5 attaches files by links in the page,
    // which the editor shows as cards where a link stands on its own line,
    // but a link in a sentence, list or quote stays text, and is listed here
    // to be played or opened.
    final listed = _note?.data.files ?? <Map<String, dynamic>>[];
    final controller = _contentController;
    final carded = <String>{
      if (controller != null)
        for (final card in noteFileCardsIn(controller.document)) card.id,
    };
    final files = [
      ...listed,
      if (controller != null)
        for (final link in noteFileLinksInMarkdown(_contentMarkdown))
          if (!carded.contains(link.id) &&
              !listed.any((file) => file['id']?.toString() == link.id))
            link.toAttachment(),
    ];

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
              if (_accessNotice(AppLocalizations.of(context)!)
                  case final notice?)
                _buildAccessNotice(context, notice),
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
              onTap: () => _openNoteFile(file),
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
    ConduitHaptics.lightImpact();
    var pageRemoved = false;
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
    final api = _openApi;
    final db = _openDb;
    final authEpoch = _openAuthEpoch;
    final userId = _openUserId;
    if (db == null || !_isOpenSessionCurrent) return;
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
          _installContentDocument(noteDocumentFromMarkdown(''));
          _savedMarkdown = '';
          _linkBase = '';
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
        pageRemoved = _settlePage(note);
        _dropDictation();
        _installContentDocument(noteDocumentFromMarkdown(_pageMarkdown(note)));
        _savedMarkdown = _contentMarkdown;
        _linkBase = _pageMarkdown(note);
        _updateWordCount();
      });
      if (pageRemoved && mounted) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.notePageRemoved,
          type: AdaptiveSnackBarType.info,
        );
      }
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
        readOnly: _readOnly,
        embedBuilder: _buildEmbed,
        contextMenuBuilder: AdaptiveDocumentSelectionMenu.richText,
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

  /// A file the page links on a line of its own shows as a card, as on the
  /// web; other embeds as Fleather draws them.
  Widget _buildEmbed(BuildContext context, EmbedNode node) {
    final file = noteFileOfEmbed(node.value);
    if (file == null) return defaultFleatherEmbedBuilder(context, node);
    final attachment = file.toAttachment();
    return Padding(
      key: ValueKey<String>('note-file-card-${file.id}'),
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: NoteFileAttachment(
        file: attachment,
        onTap: () => _openNoteFile(attachment),
        onDelete: _readOnly ? null : () => _removeFileCard(file),
        showDelete: !_readOnly,
      ),
    );
  }

  /// Takes the card for [file] out of the page, after asking; the next save
  /// detaches it.
  Future<void> _removeFileCard(NoteFileLink file) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.removeFile,
      message: l10n.removeFileConfirm,
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    );
    final controller = _contentController;
    if (confirmed != true || !mounted || _readOnly || controller == null) {
      return;
    }
    // The removal is saved through the session active now, which must be the
    // one the page opened under.
    if (!_isOpenSessionCurrent) {
      _showError(l10n.noteSessionChangedNotice);
      return;
    }
    // Dictation rewrites the text it wrote by its place, which the removal
    // moves.
    setState(_dropDictation);
    removeNoteFileCardsInEditor(controller, file.id);
    // An older note may also list the file; the list goes the same way.
    final listed = _note?.data.files ?? const <Map<String, dynamic>>[];
    if (listed.any((entry) => entry['id']?.toString() == file.id)) {
      try {
        final updated = await _attachments.removeAttachedFile(file.id);
        if (mounted && updated != null) setState(() => _note = updated);
      } on NoteWriteDeniedException {
        // Access went away: the draft stays, and is not saved again.
        _saveDebounce?.cancel();
        if (mounted) setState(() => _writeRefused = true);
      } catch (e) {
        _showError(e.toString());
      }
    }
  }

  /// Builds a Fleather theme derived from the app's typography and colours so
  /// the rich-text editor matches the rest of the note UI.
  FleatherThemeData _buildFleatherTheme(BuildContext context) {
    return buildNoteEditorFleatherTheme(context);
  }

  /// Opens [file] the way its kind needs: an audio file in the player, any
  /// other file downloaded and shared, so an app that can open it does, as
  /// the chat does with a file it cannot show.
  Future<void> _openNoteFile(Map<String, dynamic> file) async {
    final local = file['_localPath']?.toString();
    final isAudio =
        (local != null && local.isNotEmpty) ||
        file['type'] == 'audio' ||
        FileTypeUtils.isAudio(
          FileTypeUtils.extensionFromName(file['name']?.toString() ?? ''),
        );
    if (isAudio) return _playAudioFile(file);

    final l10n = AppLocalizations.of(context)!;
    final fileId = file['id']?.toString();
    final api = ref.read(apiServiceProvider);
    if (fileId == null || api == null || !_isOpenSessionCurrent) return;
    final renderObject = context.findRenderObject();
    final shareOrigin = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    final rawName = file['name']?.toString() ?? '';
    final name = rawName.trim().isEmpty ? fileId : rawName;
    // The file is the account's that opened the page, read with its
    // credentials; another signed in meanwhile gets no share sheet for it.
    final auth = api.captureAuthSnapshot();
    bool stillOpen() => mounted && _isOpenSessionCurrent;
    try {
      final content = await api.getFileContent(
        fileId,
        authSnapshot: auth,
        maxBytes: kNoteFileShareMaxBytes,
      );
      if (!stillOpen()) return;
      final encoded = content.startsWith('data:')
          ? content.substring(content.indexOf(',') + 1)
          : content;
      // A folder of this download's own, gone once the share sheet closes,
      // so a second tap cannot write over a file being shared and the note's
      // file does not stay behind.
      final folder = await createNoteFileDownloadFolder(
        (await getTemporaryDirectory()).path,
        fileId,
      );
      try {
        final path = '${folder.path}/${noteFileDownloadName(name)}';
        // Up to the share limit of bytes: decoded off the UI isolate, so the
        // editor does not stall.
        final bytes = await compute(base64Decode, encoded);
        if (!stillOpen()) return;
        await File(path).writeAsBytes(bytes, flush: true);
        if (!stillOpen()) return;
        await SharePlus.instance.share(
          ShareParams(
            files: <XFile>[XFile(path, name: name)],
            sharePositionOrigin: shareOrigin,
          ),
        );
      } finally {
        await folder.delete(recursive: true);
      }
    } catch (_) {
      if (mounted) _showError(l10n.errorMessage);
    }
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

    if (confirmed != true || _note == null || _readOnly) return;

    final localUploadId = file['_localAudioUploadId']?.toString();
    if (localUploadId != null && localUploadId.isNotEmpty) {
      await _attachments.removePending(localUploadId);
      return;
    }

    // A 0.12.5 server attaches a file by a link in the page content: one the
    // editor shows comes out of its text too, and is saved without it.
    final fileId = file['id']?.toString();
    final shownInText =
        fileId != null &&
        noteFileLinksInMarkdown(
          _contentMarkdown,
        ).any((link) => link.id == fileId);
    // The page's text loses the link once the removal is done, which moves
    // the text dictation rewrites by place: it ends now.
    if (shownInText) setState(_dropDictation);

    final api = _openApi;
    final db = _openDb;
    if (api == null && db == null) return;
    if (!_isOpenSessionCurrent) {
      _showError(l10n.noteSessionChangedNotice);
      return;
    }

    setState(() => _isSaving = true);
    // The file comes out of the page shown now; the editor stays on it until
    // the removal is done ([_showPage] waits for this).
    final pageId = _pageId;
    _removingFile = true;

    try {
      // The stored note decides what is removed: its list on a server
      // before 0.12.5, its link in the content on 0.12.5, wherever it sits
      // there now.
      final updatedNote = await _attachments.removeAttachedFile(fileId);

      if (mounted) {
        if (updatedNote != null) {
          final onPage = shownInText && _pageId == pageId;
          setState(() {
            _note = updatedNote;
            _isSaving = false;
            final controller = _contentController;
            if (onPage && controller != null) {
              // Dictation rewrites its text by place, which this moves.
              _dropDictation();
              removeNoteFileCardsInEditor(controller, fileId);
              // A link in a sentence or list is not a card; it goes too.
              if (noteFileLinksInMarkdown(
                _contentMarkdown,
              ).any((link) => link.id == fileId)) {
                _installContentDocument(
                  noteDocumentFromMarkdown(
                    removeNoteFileLinks(_contentMarkdown, fileId),
                  ),
                );
              }
              _hasChanges = true;
              _updateWordCount();
            }
            _showFileLinksOf(updatedNote);
          });
          _removingFile = false;
          if (onPage) await _saveNote(showFeedback: false);
          if (!mounted) return;

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
    } finally {
      _removingFile = false;
    }
  }

  /// Why the note cannot be edited, or null when it can.
  String? _accessNotice(AppLocalizations l10n) {
    final note = _note;
    if (note == null) return null;
    if (_writeRefused) return l10n.noteAccessRevokedNotice;
    if (_pageMissing) return l10n.notePageMissingNotice;
    return switch (noteWriteAccess(note, accountId: _openUserId)) {
      NoteWriteAccess.allowed => null,
      NoteWriteAccess.denied => switch (_sharedOwnerName(note)) {
        final String owner => l10n.libraryNoteSharedBy(owner),
        null => l10n.noteReadOnlyNotice,
      },
      NoteWriteAccess.unknown => l10n.noteAccessUnverifiedNotice,
    };
  }

  /// The name of whoever shared [note] with this account, when known. A note
  /// that does not carry its owner's name has it looked up once, through the
  /// lookup of the account the page opened under.
  String? _sharedOwnerName(Note note) {
    final named = noteSharedOwner(note, accountId: _openUserId)?.name?.trim();
    if (named != null && named.isNotEmpty) return named;
    final ownerId = note.userId;
    if (ownerId == null || ownerId.isEmpty || ownerId == _openUserId) {
      return null;
    }
    if (_ownerLookupFor == ownerId) return _resolvedOwnerName;
    // Until the account's lookup exists (a cold start or a deep link), try
    // again on a later build rather than marking the owner as looked up.
    final lookup = ref.read(workspacePrincipalLookupProvider);
    if (lookup == null || !_isOpenSessionCurrent) return null;
    _ownerLookupFor = ownerId;
    _resolvedOwnerName = null;
    unawaited(() async {
      await lookup.resolve([(type: WorkspacePrincipalType.user, id: ownerId)]);
      // A name read for another account is never shown here.
      if (!mounted ||
          _ownerLookupFor != ownerId ||
          !identical(ref.read(workspacePrincipalLookupProvider), lookup) ||
          !_isOpenSessionCurrent) {
        return;
      }
      final name = lookup
          .cached(WorkspacePrincipalType.user, ownerId)
          ?.name
          .trim();
      if (name != null && name.isNotEmpty) {
        setState(() => _resolvedOwnerName = name);
      }
    }());
    return null;
  }

  /// Saves what is on screen as a new note the user owns, through the same
  /// recovery used when a note is deleted under an open editor.
  Future<void> _saveDraftAsOwnNote() async {
    if (_savingAsOwnNote) return;
    // The draft being saved must stay as it is until the new note holds it:
    // Discard and other pages wait.
    setState(() => _savingAsOwnNote = true);
    try {
      await _saveDraftAsOwnNoteOnce();
    } finally {
      if (mounted) setState(() => _savingAsOwnNote = false);
    }
  }

  Future<void> _saveDraftAsOwnNoteOnce() async {
    final session = NoteRecoverySession(
      api: _openApi,
      db: _openDb,
      authEpoch: _openAuthEpoch,
      userId: _openUserId,
    );
    // The text of a page a sync removed takes only that page's recordings;
    // the note keeps the others.
    await _recovery.recover(session, pageId: _pageMissing ? _pageId : null);
    // The recovery rebinds the editor to the new note, which the user owns.
    if (mounted && !_hasChanges) {
      setState(() {
        _writeRefused = false;
        _pageMissing = false;
      });
    }
  }

  void _discardDraft() {
    if (_savingAsOwnNote) return;
    _saveDebounce?.cancel();
    // A save as a note of its own that failed is not retried for a draft the
    // user discarded.
    _recovery.forgetPendingRetry();
    setState(() {
      _hasChanges = false;
      _pageMissing = false;
      _titleController.text = _note?.title ?? '';
      if (_note != null) _settlePage(_note!);
      _installContentDocument(
        noteDocumentFromMarkdown(_note == null ? '' : _pageMarkdown(_note!)),
      );
      _savedMarkdown = _contentMarkdown;
      _linkBase = _note == null ? '' : _pageMarkdown(_note!);
      _updateWordCount();
    });
  }

  Widget _buildAccessNotice(BuildContext context, String notice) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: DecoratedBox(
        key: const ValueKey<String>('note-access-notice'),
        decoration: BoxDecoration(
          color: theme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
          border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Platform.isIOS ? CupertinoIcons.lock : Icons.lock_outline,
                    size: IconSize.small,
                    color: theme.iconSecondary,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      notice,
                      style: theme.bodySmall?.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              if ((_writeRefused || _pageMissing) && _hasChanges) ...[
                const SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.sm,
                  children: [
                    ConduitButton(
                      key: const ValueKey<String>('note-save-as-own'),
                      text: l10n.noteSaveAsOwnNote,
                      isCompact: true,
                      onPressed: _savingAsOwnNote ? null : _saveDraftAsOwnNote,
                    ),
                    ConduitButton(
                      key: const ValueKey<String>('note-discard-draft'),
                      text: l10n.noteDiscardChanges,
                      isCompact: true,
                      isSecondary: true,
                      onPressed: _savingAsOwnNote ? null : _discardDraft,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
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

    final headline = _loadForbidden
        ? l10n.noteNoAccess
        : _sessionChanged
        ? l10n.noteSessionChangedNotice
        : l10n.noteNotFound;
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
              headline,
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
