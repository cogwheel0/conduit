import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/models/note.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/improved_loading_states.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../chat/services/voice_input_service.dart';
import '../providers/notes_providers.dart';
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
  final TextEditingController _contentController = TextEditingController();
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

  // Voice input
  VoiceInputService? _voiceService;
  StreamSubscription<String>? _voiceSub;
  String _voiceBaseText = '';

  int get _wordCount {
    final text = _contentController.text.trim();
    if (text.isEmpty) return 0;
    return text.split(RegExp(r'\s+')).length;
  }

  int get _charCount => _contentController.text.length;

  @override
  void initState() {
    super.initState();
    _loadNote();
    _titleController.addListener(_onContentChanged);
    _contentController.addListener(_onContentChanged);
    // Rebuild when title focus changes to show/hide the generate title button
    _titleFocusNode.addListener(_onTitleFocusChanged);
  }

  void _onTitleFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _voiceSub?.cancel();
    _voiceService?.stopListening();
    _titleController.dispose();
    _contentController.dispose();
    _titleFocusNode.removeListener(_onTitleFocusChanged);
    _titleFocusNode.dispose();
    _contentFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadNote() async {
    setState(() => _isLoading = true);

    final api = ref.read(apiServiceProvider);
    if (api == null) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      final json = await api.getNoteById(widget.noteId);
      final note = Note.fromJson(json);

      if (mounted) {
        setState(() {
          _note = note;
          _titleController.text = note.title;
          _contentController.text = note.markdownContent;
          _isLoading = false;
          _hasChanges = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showError(e.toString());
      }
    }
  }

  void _onContentChanged() {
    if (!mounted || _isLoading) return;

    // Check if content actually changed from the saved note
    final titleChanged = _note != null && _titleController.text != _note!.title;
    final contentChanged =
        _note != null && _contentController.text != _note!.markdownContent;
    final hasRealChanges = titleChanged || contentChanged;

    if (hasRealChanges != _hasChanges) {
      setState(() => _hasChanges = hasRealChanges);
    }

    if (hasRealChanges) {
      _debounceSave();
    }
  }

  void _debounceSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), _autoSave);
  }

  Future<void> _autoSave() async {
    if (_note == null || !_hasChanges) return;
    await _saveNote(showFeedback: false);
  }

  Future<void> _saveNote({bool showFeedback = true}) async {
    if (_note == null) return;

    setState(() => _isSaving = true);

    final api = ref.read(apiServiceProvider);
    if (api == null) {
      setState(() => _isSaving = false);
      return;
    }

    try {
      final title = _titleController.text.trim();
      final content = _contentController.text;

      final data = <String, dynamic>{
        'content': <String, dynamic>{
          'json': null,
          'html': _markdownToHtml(content),
          'md': content,
        },
      };

      // Use the server's response to get authoritative data (including updated_at)
      final json = await api.updateNote(
        widget.noteId,
        title: title.isEmpty ? AppLocalizations.of(context)!.untitled : title,
        data: data,
      );

      final updatedNote = Note.fromJson(json);

      ref.read(notesListProvider.notifier).updateNote(updatedNote);

      if (mounted) {
        setState(() {
          _note = updatedNote;
          _isSaving = false;
          _hasChanges = false;
        });

        if (showFeedback) {
          HapticFeedback.lightImpact();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        _showError(e.toString());
      }
    }
  }

  String _markdownToHtml(String markdown) {
    final paragraphs = markdown.split('\n\n');
    final html = paragraphs
        .map((p) {
          if (p.trim().isEmpty) return '';
          if (p.startsWith('# ')) {
            return '<h1>${_escapeHtml(p.substring(2))}</h1>';
          }
          if (p.startsWith('## ')) {
            return '<h2>${_escapeHtml(p.substring(3))}</h2>';
          }
          if (p.startsWith('### ')) {
            return '<h3>${_escapeHtml(p.substring(4))}</h3>';
          }
          // Escape entire paragraph first to prevent XSS, then apply
          // markdown formatting replacements on the escaped text.
          var text = _escapeHtml(p);
          text = text.replaceAllMapped(
            RegExp(r'\*\*(.+?)\*\*'),
            (m) => '<strong>${m.group(1)!}</strong>',
          );
          text = text.replaceAllMapped(
            RegExp(r'\*(.+?)\*'),
            (m) => '<em>${m.group(1)!}</em>',
          );
          return '<p>$text</p>';
        })
        .join('\n');
    return html;
  }

  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: context.conduitTheme.error,
      ),
    );
  }

  Future<bool> _onWillPop() async {
    if (_hasChanges) {
      await _saveNote(showFeedback: false);
    }
    return true;
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
      HapticFeedback.mediumImpact();
      final success = await ref
          .read(noteDeleterProvider.notifier)
          .deleteNote(widget.noteId);
      if (success && mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  // Get the selected model ID for AI operations
  String? _getSelectedModelId() {
    final selectedModel = ref.read(selectedModelProvider);
    return selectedModel?.id;
  }

  // AI title generation
  Future<void> _generateTitle() async {
    if (_note == null || _isGeneratingTitle) return;
    final content = _contentController.text.trim();
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
    HapticFeedback.lightImpact();

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
        HapticFeedback.mediumImpact();
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
    final content = _contentController.text.trim();
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
    HapticFeedback.lightImpact();

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
        _contentController.text = enhancedContent;
        HapticFeedback.mediumImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.noteEnhanced),
            duration: const Duration(seconds: 2),
          ),
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

      setState(() {
        _isRecording = true;
        _voiceBaseText = _contentController.text;
      });

      HapticFeedback.lightImpact();

      _voiceSub?.cancel();
      _voiceSub = stream.listen(
        (text) {
          if (!mounted) return;
          final updated = _voiceBaseText.isEmpty
              ? text
              : '${_voiceBaseText.trimRight()} $text';
          _contentController.value = TextEditingValue(
            text: updated,
            selection: TextSelection.collapsed(offset: updated.length),
          );
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
    if (mounted) {
      setState(() => _isRecording = false);
      HapticFeedback.selectionClick();
    }
  }

  /// Shows a bottom sheet to choose between dictation and audio recording.
  void _showRecordingOptions() {
    final conduitTheme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: conduitTheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.modal),
        ),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: Spacing.md),
                decoration: BoxDecoration(
                  color: conduitTheme.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(AppBorderRadius.round),
                ),
              ),
              // Dictation option
              ListTile(
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
                  style: TextStyle(
                    color: conduitTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  l10n.dictationDescription,
                  style: TextStyle(
                    color: conduitTheme.textSecondary,
                    fontSize: AppTypography.bodySmall,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _toggleDictation();
                },
              ),
              const SizedBox(height: Spacing.xs),
              // Audio recording option
              ListTile(
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppBorderRadius.md),
                  ),
                  child: Icon(
                    Platform.isIOS
                        ? CupertinoIcons.mic_fill
                        : Icons.mic_rounded,
                    color: Colors.red,
                    size: IconSize.md,
                  ),
                ),
                title: Text(
                  l10n.recordAudio,
                  style: TextStyle(
                    color: conduitTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  l10n.recordAudioDescription,
                  style: TextStyle(
                    color: conduitTheme.textSecondary,
                    fontSize: AppTypography.bodySmall,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showAudioRecordingOverlay();
                },
              ),
            ],
          ),
        ),
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
                Navigator.pop(context);
                await _uploadAudioFile(file);
              },
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 150),
      ),
    );
  }

  /// Uploads an audio file to the server and attaches it to the note.
  Future<void> _uploadAudioFile(File audioFile) async {
    final api = ref.read(apiServiceProvider);
    final l10n = AppLocalizations.of(context)!;

    if (api == null || _note == null) {
      _showError(l10n.failedToUploadAudio);
      return;
    }

    setState(() => _isUploadingAudio = true);

    try {
      // Get file info
      final fileSize = await audioFile.length();
      final fileName = 'recording_${DateTime.now().millisecondsSinceEpoch}.m4a';

      // Upload file to Open WebUI with proper content type
      final fileId = await api.uploadFile(
        audioFile.path,
        fileName,
        contentType: 'audio/mp4',
      );

      // Get current note files
      final currentFiles = _note!.data.files ?? [];

      // Generate a local item ID (for OpenWebUI compatibility)
      final itemId = DateTime.now().millisecondsSinceEpoch.toString();

      // Add the new file in OpenWebUI's expected format
      // Must match the structure in NoteEditor.svelte uploadFileHandler
      final updatedFiles = [
        ...currentFiles,
        {
          'type': 'file',
          'file': '',
          'id': fileId,
          'url': fileId,
          'name': fileName,
          'collection_name': '',
          'status': 'uploaded',
          'size': fileSize,
          'error': '',
          'itemId': itemId,
        },
      ];

      debugPrint('NoteEditorPage: Saving files: $updatedFiles');

      // Update note with the file attachment
      final data = <String, dynamic>{
        'content': <String, dynamic>{
          'json': null,
          'html': _markdownToHtml(_contentController.text),
          'md': _contentController.text,
        },
        'files': updatedFiles,
      };

      debugPrint('NoteEditorPage: Updating note with data: $data');

      final json = await api.updateNote(
        widget.noteId,
        title: _titleController.text.isEmpty ? l10n.untitled : _titleController.text,
        data: data,
      );

      debugPrint('NoteEditorPage: Update response: $json');
      debugPrint('NoteEditorPage: Response files: ${json['data']?['files']}');

      final updatedNote = Note.fromJson(json);

      if (mounted) {
        // Update provider state inside mounted check to avoid accessing
        // invalid ref after widget disposal
        ref.read(notesListProvider.notifier).updateNote(updatedNote);

        setState(() {
          _note = updatedNote;
          _isUploadingAudio = false;
          _hasChanges = false;
        });

        HapticFeedback.mediumImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.audioRecordingSaved),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      // Clean up temp file
      try {
        await audioFile.delete();
      } catch (_) {
        // Ignore cleanup errors
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUploadingAudio = false);
        _showError('Failed to upload audio: $e');
      }
    }
  }

  void _copyToClipboard() {
    final l10n = AppLocalizations.of(context)!;
    final content = _contentController.text;
    Clipboard.setData(ClipboardData(text: content));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.noteCopiedToClipboard),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sidebarTheme = context.sidebarTheme;

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
      return Scaffold(backgroundColor: sidebarTheme.background);
    }

    return PopScope(
      // Only allow immediate pop when there are no unsaved changes.
      // When there are changes, we intercept, save first, then pop manually.
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return; // Already popped, nothing to do
        // Capture navigator before async gap
        final navigator = Navigator.of(context);
        // Save changes before allowing pop
        await _saveNote(showFeedback: false);
        if (!mounted) return;
        navigator.pop();
      },
      child: ErrorBoundary(
        child: Scaffold(
          backgroundColor: context.conduitTheme.surfaceBackground,
          extendBodyBehindAppBar: true,
          appBar: _buildAppBar(context),
          body: Stack(
            children: [
              // Main content - scrolls behind floating elements
              Positioned.fill(
                child: _buildMainContent(context),
              ),
              // Floating action buttons
              if (!_isLoading && _note != null)
                Positioned(
                  left: Spacing.md,
                  right: Spacing.md,
                  bottom: Spacing.md + MediaQuery.of(context).padding.bottom,
                  child: _buildFloatingActionsRow(context),
                ),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final theme = Theme.of(context);
    final conduitTheme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight + 40),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0.0, 0.4, 1.0],
            colors: [
              theme.scaffoldBackgroundColor,
              theme.scaffoldBackgroundColor.withValues(alpha: 0.85),
              theme.scaffoldBackgroundColor.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // App bar row with back button, title, and menu
              SizedBox(
                height: kToolbarHeight,
                child: Row(
                  children: [
                    // Leading (back button)
                    Padding(
                      padding: const EdgeInsets.only(left: Spacing.inputPadding),
                      child: Center(
                        child: GestureDetector(
                          onTap: () async {
                            final navigator = Navigator.of(context);
                            await _onWillPop();
                            if (!mounted) return;
                            navigator.pop();
                          },
                          child: _buildAppBarPill(
                            context,
                            Icon(
                              UiUtils.platformIcon(
                                ios: CupertinoIcons.back,
                                android: Icons.arrow_back,
                              ),
                              color: conduitTheme.textPrimary,
                              size: IconSize.appBar,
                            ),
                            isCircular: true,
                          ),
                        ),
                      ),
                    ),
                    // Title centered
                    Expanded(
                      child: Center(
                        child: _buildAppBarPill(
        context,
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.xs,
          ),
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
                            style: AppTypography.bodyMediumStyle.copyWith(
                              color: conduitTheme.textSecondary,
                            ),
                          ),
                        ],
                      )
                    : ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.5,
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Hidden TextField always in tree for focus
                            Opacity(
                              opacity: _titleFocusNode.hasFocus ? 1.0 : 0.0,
                              child: IntrinsicWidth(
                                child: TextField(
                                  controller: _titleController,
                                  focusNode: _titleFocusNode,
                                  enabled: !_isGeneratingTitle,
                                  style: AppTypography.headlineSmallStyle
                                      .copyWith(
                                        color: conduitTheme.textPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                  decoration: InputDecoration(
                                    hintText: l10n.untitled,
                                    hintStyle: AppTypography.headlineSmallStyle
                                        .copyWith(
                                          color: conduitTheme.textSecondary
                                              .withValues(alpha: 0.6),
                                          fontWeight: FontWeight.w600,
                                        ),
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                    isDense: true,
                                  ),
                                  textAlign: TextAlign.center,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) =>
                                      _contentFocusNode.requestFocus(),
                                ),
                              ),
                            ),
                            // Visible text when not focused
                            if (!_titleFocusNode.hasFocus)
                              GestureDetector(
                                onTap: () => _titleFocusNode.requestFocus(),
                                child: MiddleEllipsisText(
                                  _titleController.text.isEmpty
                                      ? l10n.untitled
                                      : _titleController.text,
                                  style: AppTypography.headlineSmallStyle
                                      .copyWith(
                                        color: _titleController.text.isEmpty
                                            ? conduitTheme.textSecondary
                                                .withValues(alpha: 0.6)
                                            : conduitTheme.textPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ),
                          ],
                        ),
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
                      ),
                    ),
                    // Actions (more menu) - uses PopupMenuButton for tap interaction
                    Padding(
                      padding: const EdgeInsets.only(right: Spacing.inputPadding),
                      child: Center(
                        child: PopupMenuButton<String>(
                          onSelected: (value) {
                            switch (value) {
                              case 'generate':
                                HapticFeedback.selectionClick();
                                _generateTitle();
                              case 'copy':
                                HapticFeedback.selectionClick();
                                _copyToClipboard();
                              case 'delete':
                                HapticFeedback.mediumImpact();
                                _deleteNote();
                            }
                          },
                          offset: const Offset(0, 44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              AppBorderRadius.card,
                            ),
                          ),
                          color: conduitTheme.surfaceContainer,
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'generate',
                              child: Row(
                                children: [
                                  Icon(
                                    Platform.isIOS
                                        ? CupertinoIcons.sparkles
                                        : Icons.auto_awesome_rounded,
                                    size: IconSize.small,
                                    color: conduitTheme.textPrimary,
                                  ),
                                  const SizedBox(width: Spacing.sm),
                                  Text(
                                    l10n.generateTitle,
                                    style: TextStyle(
                                      color: conduitTheme.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'copy',
                              child: Row(
                                children: [
                                  Icon(
                                    Platform.isIOS
                                        ? CupertinoIcons.doc_on_clipboard
                                        : Icons.copy_rounded,
                                    size: IconSize.small,
                                    color: conduitTheme.textPrimary,
                                  ),
                                  const SizedBox(width: Spacing.sm),
                                  Text(
                                    l10n.copy,
                                    style: TextStyle(
                                      color: conduitTheme.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(
                                    Platform.isIOS
                                        ? CupertinoIcons.delete
                                        : Icons.delete_rounded,
                                    size: IconSize.small,
                                    color: conduitTheme.error,
                                  ),
                                  const SizedBox(width: Spacing.sm),
                                  Text(
                                    l10n.delete,
                                    style: TextStyle(
                                      color: conduitTheme.error,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          child: _buildAppBarPill(
                            context,
                            Icon(
                              Platform.isIOS
                                  ? CupertinoIcons.ellipsis
                                  : Icons.more_vert_rounded,
                              color: conduitTheme.textPrimary,
                              size: IconSize.appBar,
                            ),
                            isCircular: true,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Metadata stats row
              if (!_isLoading && _note != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.xs),
                  child: _buildFloatingMetadataBar(context),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBarPill(
    BuildContext context,
    Widget child, {
    bool isCircular = false,
  }) {
    return FloatingAppBarPill(
      isCircular: isCircular,
      child: child,
    );
  }

  Widget _buildFloatingMetadataBar(BuildContext context) {
    final conduitTheme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    // Use consistent colors with the floating app bar pills
    final backgroundColor = conduitTheme.surfaceContainer.withValues(alpha: 0.9);
    final borderColor = conduitTheme.surfaceContainerHighest.withValues(
      alpha: 0.4,
    );

    final dateFormat = DateFormat.MMMd();
    final timeFormat = DateFormat.jm();
    final createdDate = _note != null
        ? '${dateFormat.format(_note!.createdDateTime)} ${timeFormat.format(_note!.createdDateTime)}'
        : '';

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppBorderRadius.pill),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xs,
          ),
          decoration: BoxDecoration(
            color: backgroundColor.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(AppBorderRadius.pill),
            border: Border.all(color: borderColor, width: BorderWidth.thin),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Created date
              _buildMetadataChip(
                context,
                icon: Platform.isIOS
                    ? CupertinoIcons.calendar
                    : Icons.calendar_today_rounded,
                label: createdDate,
              ),
              _buildMetadataSeparator(conduitTheme),
              // Word count
              _buildMetadataChip(
                context,
                icon: Platform.isIOS
                    ? CupertinoIcons.doc_text
                    : Icons.article_rounded,
                label: l10n.wordCount(_wordCount),
              ),
              _buildMetadataSeparator(conduitTheme),
              // Character count
              _buildMetadataChip(
                context,
                icon: Platform.isIOS
                    ? CupertinoIcons.textformat_abc
                    : Icons.text_fields_rounded,
                label: l10n.charCount(_charCount),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetadataSeparator(ConduitThemeExtension theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xxs),
      child: Text(
        '·',
        style: AppTypography.tiny.copyWith(
          color: theme.textSecondary.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _buildMetadataChip(
    BuildContext context, {
    required IconData icon,
    required String label,
  }) {
    final theme = context.conduitTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.xs,
        vertical: Spacing.xxs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: theme.textSecondary,
            size: IconSize.xs,
          ),
          const SizedBox(width: Spacing.xxs),
          Text(
            label,
            style: AppTypography.tiny.copyWith(
              color: theme.textSecondary,
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
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final topPadding = MediaQuery.of(context).padding.top;
    // App bar height: kToolbarHeight + metadata bar (~40)
    final appBarHeight = kToolbarHeight + 40;

    // Get attached files
    final files = _note?.data.files ?? [];

    return GestureDetector(
      onTap: () => _contentFocusNode.requestFocus(),
      behavior: HitTestBehavior.opaque,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          Spacing.inputPadding,
          topPadding + appBarHeight + Spacing.sm, // Space for floating app bar
          Spacing.inputPadding,
          120, // Extra padding for floating buttons
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File attachments section (if any)
            if (files.isNotEmpty) ...[
              NoteFilesSection(
                files: files,
                onPlayFile: _playAudioFile,
                onDeleteFile: _removeFile,
              ),
              const SizedBox(height: Spacing.lg),
            ],
            // Content editor
            TextField(
              controller: _contentController,
              focusNode: _contentFocusNode,
              style: AppTypography.bodyLargeStyle.copyWith(
                color: theme.textPrimary,
                height: 1.8,
              ),
              decoration: InputDecoration(
                hintText: l10n.writeNote,
                hintStyle: AppTypography.bodyLargeStyle.copyWith(
                  color: theme.textSecondary.withValues(alpha: 0.35),
                  height: 1.8,
                ),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              maxLines: null,
              minLines: 20,
              textAlignVertical: TextAlignVertical.top,
              textCapitalization: TextCapitalization.sentences,
              keyboardType: TextInputType.multiline,
            ),
          ],
        ),
      ),
    );
  }

  /// Play an audio file attachment.
  Future<void> _playAudioFile(Map<String, dynamic> file) async {
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.removeFile),
        content: Text(l10n.removeFileConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: context.conduitTheme.error,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );

    if (confirmed != true || _note == null) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    setState(() => _isSaving = true);

    try {
      final fileId = file['id']?.toString();
      final currentFiles = _note!.data.files ?? [];
      final updatedFiles = currentFiles
          .where((f) => f['id']?.toString() != fileId)
          .toList();

      final data = <String, dynamic>{
        'content': <String, dynamic>{
          'json': null,
          'html': _markdownToHtml(_contentController.text),
          'md': _contentController.text,
        },
        'files': updatedFiles,
      };

      final json = await api.updateNote(
        widget.noteId,
        title: _titleController.text.isEmpty
            ? l10n.untitled
            : _titleController.text,
        data: data,
      );

      final updatedNote = Note.fromJson(json);
      ref.read(notesListProvider.notifier).updateNote(updatedNote);

      if (mounted) {
        setState(() {
          _note = updatedNote;
          _isSaving = false;
          _hasChanges = false;
        });

        HapticFeedback.lightImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.fileRemoved),
            duration: const Duration(seconds: 2),
          ),
        );
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
              ? (Platform.isIOS
                    ? CupertinoIcons.stop_fill
                    : Icons.stop_rounded)
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
    final theme = Theme.of(context);
    final conduitTheme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final isDark = theme.brightness == Brightness.dark;

    final backgroundColor = isDark
        ? Color.lerp(conduitTheme.cardBackground, Colors.white, 0.08)!
            .withValues(alpha: 0.85)
        : Color.lerp(conduitTheme.inputBackground, Colors.black, 0.06)!
            .withValues(alpha: 0.85);

    final borderColor = conduitTheme.cardBorder.withValues(alpha: 0.55);

    final buttonChild = ClipRRect(
      borderRadius: BorderRadius.circular(AppBorderRadius.floatingButton),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: TouchTarget.button,
          height: TouchTarget.button,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(AppBorderRadius.floatingButton),
            border: Border.all(color: borderColor, width: BorderWidth.thin),
            boxShadow: ConduitShadows.button(context),
          ),
          child: isLoading
              ? Center(
                  child: SizedBox(
                    width: IconSize.md,
                    height: IconSize.md,
                    child: CircularProgressIndicator(
                      strokeWidth: BorderWidth.medium,
                      valueColor:
                          AlwaysStoppedAnimation(conduitTheme.loadingIndicator),
                    ),
                  ),
                )
              : Icon(
                  icon,
                  color: color ??
                      conduitTheme.iconPrimary.withValues(alpha: 0.9),
                  size: IconSize.lg,
                ),
        ),
      ),
    );

    if (showMenu) {
      return PopupMenuButton<String>(
        tooltip: tooltip,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
        ),
        offset: const Offset(0, -120),
        onSelected: (value) {
          switch (value) {
            case 'enhance':
              _enhanceContent();
            case 'title':
              _generateTitle();
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'enhance',
            child: Row(
              children: [
                Icon(
                  Platform.isIOS
                      ? CupertinoIcons.sparkles
                      : Icons.auto_fix_high_rounded,
                  color: conduitTheme.buttonPrimary,
                  size: IconSize.md,
                ),
                const SizedBox(width: Spacing.sm),
                Text(l10n.enhanceNote),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'title',
            child: Row(
              children: [
                Icon(
                  Platform.isIOS
                      ? CupertinoIcons.textformat
                      : Icons.title_rounded,
                  color: conduitTheme.buttonPrimary,
                  size: IconSize.md,
                ),
                const SizedBox(width: Spacing.sm),
                Text(l10n.generateTitle),
              ],
            ),
          ),
        ],
        child: buttonChild,
      );
    }

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppBorderRadius.floatingButton),
          ),
          child: buttonChild,
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
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(
                Platform.isIOS ? CupertinoIcons.back : Icons.arrow_back_rounded,
              ),
              label: Text(l10n.goBack),
              style: OutlinedButton.styleFrom(
                foregroundColor: sidebarTheme.primary,
                side: BorderSide(
                  color: sidebarTheme.primary.withValues(alpha: 0.5),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppBorderRadius.button),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
