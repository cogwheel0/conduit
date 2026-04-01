import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../../../shared/theme/qonduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/glass_colors.dart';
// app_theme not required here; using theme extension tokens
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io' show Platform;
import 'dart:async';
import '../providers/chat_providers.dart';
import '../services/clipboard_attachment_service.dart';
import '../services/file_attachment_service.dart';
import '../services/ios_native_paste_service.dart';
import '../providers/context_attachments_provider.dart';
import '../providers/knowledge_cache_provider.dart';
import '../../tools/providers/tools_providers.dart';
import '../../prompts/providers/prompts_providers.dart';
import '../../../core/models/tool.dart';
import '../../../core/models/model.dart';
import '../../../core/models/prompt.dart';
import '../../../core/models/toggle_filter.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/settings_service.dart';
import '../../chat/services/voice_input_service.dart';
import '../../../core/models/knowledge_base.dart';

import '../../../shared/utils/platform_utils.dart';
import 'package:qonduit/l10n/app_localizations.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../core/utils/prompt_variable_parser.dart';
import '../../prompts/widgets/prompt_variable_dialog.dart';
import '../../auth/providers/unified_auth_providers.dart';
import 'chat_input_intents.dart';
import 'expanded_text_editor.dart';
import 'composer_overflow_menu.dart';
import 'mention_text_controller.dart';
import 'model_suggestion_overlay.dart';
import 'prompt_suggestion_overlay.dart';

class ModernChatInput extends ConsumerStatefulWidget {
  final Function(String) onSendMessage;
  final bool enabled;

  /// Optional placeholder text shown when the input is empty.
  /// Falls back to the localised default ("Ask anything...").
  final String? placeholder;

  /// Builder that replaces the default overflow (+) button entirely.
  /// Receives the button size so the replacement can match layout.
  /// When provided, the default [ComposerOverflowSheet] is not used.
  final Widget Function(double size)? overflowButtonBuilder;

  final Function()? onVoiceInput;
  final Function()? onVoiceCall;
  final Function()? onFileAttachment;
  final Function()? onImageAttachment;
  final Function()? onCameraCapture;
  final Function()? onWebAttachment;
  final VoidCallback? onKnowledgeTool;
  final VoidCallback? onCodeEditTool;

  /// Callback invoked when images or files are pasted from clipboard.
  final Future<void> Function(List<LocalAttachment>)? onPastedAttachments;

  const ModernChatInput({
    super.key,
    required this.onSendMessage,
    this.enabled = true,
    this.placeholder,
    this.overflowButtonBuilder,
    this.onVoiceInput,
    this.onVoiceCall,
    this.onFileAttachment,
    this.onImageAttachment,
    this.onCameraCapture,
    this.onWebAttachment,
    this.onPastedAttachments,
    this.onKnowledgeTool,
    this.onCodeEditTool,
  });

  @override
  ConsumerState<ModernChatInput> createState() => _ModernChatInputState();
}

// (Removed legacy _MicButton; inline mic logic now lives in primary button)

class _ModernChatInputState extends ConsumerState<ModernChatInput>
    with TickerProviderStateMixin {
  bool get _useIOS26NativeControls => PlatformInfo.isIOS26OrHigher();

  static const double _composerRadius = AppBorderRadius.card;

  final MentionTextEditingController _controller =
  MentionTextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// Preserves the text field widget across parent shell swaps (e.g. when the
  /// compact shell switches between native glass and blur on multiline toggle).
  /// Without this, different parent ValueKeys cause Flutter to unmount and
  /// remount the TextField, losing focus and keyboard state.
  final GlobalKey _textFieldKey = GlobalKey();
  bool _pendingFocus = false;
  bool _isRecording = false;
  bool _hasText = false; // track locally without rebuilding on each keystroke
  bool _isMultiline = false; // track multiline for dynamic border radius
  /// Tracks the last time the user edited text, used to detect unexpected
  /// focus loss during active typing (e.g. from widget tree restructures).
  DateTime _lastEditTime = DateTime(0);
  StreamSubscription<String>? _voiceStreamSubscription;
  StreamSubscription<IosNativePastePayload>? _pasteSubscription;
  late VoiceInputService _voiceService;
  StreamSubscription<String>? _textSub;
  String _baseTextAtStart = '';
  bool _isDeactivated = false;
  int _lastHandledFocusTick = 0;
  bool _showPromptOverlay = false;
  bool _showExpandButton = false;
  bool _expandModalOpen = false;
  String _currentPromptCommand = '';
  TextRange? _currentPromptRange;
  int _promptSelectionIndex = 0;

  /// Service for handling clipboard paste operations.
  final ClipboardAttachmentService _clipboardService =
  ClipboardAttachmentService();

  @override
  void initState() {
    super.initState();
    _voiceService = ref.read(voiceInputServiceProvider);

    // Apply any prefilled text on first frame (focus handled via inputFocusTrigger)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDeactivated) return;
      final text = ref.read(prefilledInputTextProvider);
      if (text != null && text.isNotEmpty) {
        _controller.text = text;
        _controller.selection = TextSelection.collapsed(offset: text.length);
        // Clear after applying so it doesn't re-apply on rebuilds
        ref.read(prefilledInputTextProvider.notifier).clear();
      }
    });

    // Removed ref.listen here; it must be used from build in this Riverpod version

    // Listen for text and selection changes in the composer
    _controller.addListener(_handleComposerChanged);

    if (!kIsWeb && Platform.isIOS) {
      _pasteSubscription = IosNativePasteService.instance.onPaste.listen((
          payload,
          ) {
        unawaited(_handleNativePastePayload(payload));
      });
    }

    // Publish focus changes to listeners and guard against unexpected loss
    // during active editing (e.g. widget tree restructure on expansion).
    _focusNode.addListener(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDeactivated) return;
        final hasFocus = _focusNode.hasFocus;
        // Publish composer focus state
        try {
          ref.read(composerHasFocusProvider.notifier).set(hasFocus);
        } catch (_) {}

        // If focus was lost within 500ms of the last text edit, the user was
        // actively typing and the loss was likely caused by a widget tree
        // restructure (shell swap, parent rebuild from MeasureSize, etc.).
        // Only restore when text is non-empty (excludes post-send clear),
        // the widget is enabled, and autofocus hasn't been explicitly
        // suppressed (excludes body tap / scroll dismiss).
        if (!hasFocus &&
            widget.enabled &&
            !_expandModalOpen &&
            _controller.text.isNotEmpty &&
            DateTime.now().difference(_lastEditTime).inMilliseconds < 500) {
          final autofocusEnabled = ref.read(composerAutofocusEnabledProvider);
          if (autofocusEnabled) {
            _focusNode.requestFocus();
          }
        }
      });
    });

    // Do not auto-focus on mount; only focus on explicit user intent
  }

  @override
  void dispose() {
    // Note: Avoid using ref in dispose as per Riverpod best practices
    // The focus state will be naturally cleared when the widget is disposed
    _controller.removeListener(_handleComposerChanged);
    _controller.dispose();
    _focusNode.dispose();
    _pendingFocus = false;
    _voiceStreamSubscription?.cancel();
    _pasteSubscription?.cancel();
    _textSub?.cancel();
    _voiceService.stopListening();
    super.dispose();
  }

  void _ensureFocusedIfEnabled() {
    // Respect global suppression flag to avoid re-opening keyboard
    final autofocusEnabled = ref.read(composerAutofocusEnabledProvider);
    final hasFocus = _focusNode.hasFocus;
    if (!widget.enabled || hasFocus || _pendingFocus || !autofocusEnabled) {
      return;
    }

    _pendingFocus = true;
    // Request focus synchronously if we're already in a safe context,
    // otherwise defer to next frame
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // We're in a build/layout phase, defer to next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _pendingFocus = false;
        if (!widget.enabled) return;
        if (!_focusNode.hasFocus) {
          _focusNode.requestFocus();
        }
      });
    } else {
      // Safe to request focus immediately
      _pendingFocus = false;
      _focusNode.requestFocus();
    }
  }

  @override
  void deactivate() {
    _isDeactivated = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _isDeactivated = false;
  }

  @override
  void didUpdateWidget(covariant ModernChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Avoid auto-focusing when becoming enabled; wait for user intent
    if (!widget.enabled && oldWidget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDeactivated) return;
        if (_focusNode.hasFocus) {
          _focusNode.unfocus();
        }
      });
    }
  }

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled) return;

    // Convert @mentions to OpenWebUI wire format
    // (e.g. @GPT-4 → <@M:gpt-4|GPT-4>) before sending.
    final wireText = _controller.toWireFormat().trim();

    widget.onSendMessage(wireText);
    _controller.clearMentions();
    _controller.clear();
    _focusNode.unfocus();
    try {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {
      // Silently handle if keyboard dismissal fails
    }
  }

  /// Handles content insertion from keyboard/clipboard (images, files).
  ///
  /// This is called when the user pastes rich content into the text field
  /// on iOS and Android.
  Future<void> _handleContentInserted(KeyboardInsertedContent content) async {
    if (!widget.enabled) return;

    // Check if we have a callback to handle pasted attachments
    final onPasted = widget.onPastedAttachments;
    if (onPasted == null) return;

    final mimeType = content.mimeType;
    final data = content.data;

    // Only process image content
    if (!_clipboardService.isSupportedImageType(mimeType)) {
      return;
    }

    // Check if we have actual data
    if (data == null || data.isEmpty) {
      return;
    }

    PlatformUtils.lightHaptic();

    // Create attachment from pasted image data
    String? suggestedName;
    final uriString = content.uri;
    if (uriString.isNotEmpty) {
      try {
        final uri = Uri.parse(uriString);
        if (uri.pathSegments.isNotEmpty) {
          suggestedName = uri.pathSegments.last;
        }
      } catch (_) {
        // Ignore URI parsing errors
      }
    }
    final attachment = await _clipboardService.createAttachmentFromImageData(
      imageData: data,
      mimeType: mimeType,
      suggestedFileName: suggestedName,
    );

    if (attachment != null) {
      await onPasted([attachment]);
    }
  }

  /// Handles pasting images/files from clipboard with pre-loaded image data.
  ///
  /// This avoids a second clipboard read by using data already fetched when
  /// building the context menu.
  Future<void> _handleClipboardPasteWithData(Uint8List imageData) async {
    if (!widget.enabled) return;

    final onPasted = widget.onPastedAttachments;
    if (onPasted == null) return;

    PlatformUtils.lightHaptic();

    final attachment = await _clipboardService.createAttachmentFromImageData(
      imageData: imageData,
      mimeType: 'image/png',
    );
    if (attachment != null) {
      await onPasted([attachment]);
    }
  }

  Future<void> _handleNativePastePayload(IosNativePastePayload payload) async {
    if (!mounted || !widget.enabled || !_focusNode.hasFocus) {
      return;
    }

    final onPasted = widget.onPastedAttachments;
    if (onPasted == null) {
      return;
    }

    switch (payload) {
      case IosNativeTextPaste():
        return;
      case IosNativeImagePaste(:final items):
        final attachments = <LocalAttachment>[];
        for (final item in items) {
          final attachment = await _clipboardService
              .createAttachmentFromImageData(
            imageData: item.data,
            mimeType: item.mimeType,
          );
          if (attachment != null) {
            attachments.add(attachment);
          }
        }
        if (attachments.isNotEmpty) {
          await onPasted(attachments);
        }
      case IosNativeUnsupportedPaste():
        return;
    }
  }

  Widget _buildIosContextMenu(
      BuildContext context,
      EditableTextState editableTextState,
      ) {
    if (SystemContextMenu.isSupportedByField(editableTextState)) {
      return SystemContextMenu.editableText(
        editableTextState: editableTextState,
        items: _buildIosSystemContextMenuItems(editableTextState),
      );
    }

    return _buildFallbackContextMenu(context, editableTextState);
  }

  List<IOSSystemContextMenuItem> _buildIosSystemContextMenuItems(
      EditableTextState editableTextState,
      ) {
    final items = List<IOSSystemContextMenuItem>.from(
      SystemContextMenu.getDefaultItems(editableTextState),
    );

    if (widget.onPastedAttachments == null ||
        items.any((item) => item is IOSSystemContextMenuItemPaste)) {
      return items;
    }

    final pasteItem = const IOSSystemContextMenuItemPaste();
    final insertionIndex = items.indexWhere(
          (item) =>
      item is IOSSystemContextMenuItemSelectAll ||
          item is IOSSystemContextMenuItemLookUp ||
          item is IOSSystemContextMenuItemSearchWeb ||
          item is IOSSystemContextMenuItemShare ||
          item is IOSSystemContextMenuItemLiveText,
    );

    if (insertionIndex >= 0) {
      items.insert(insertionIndex, pasteItem);
    } else {
      items.add(pasteItem);
    }

    return items;
  }

  /// Builds a Flutter-rendered fallback menu with "Paste Image".
  Widget _buildFallbackContextMenu(
      BuildContext context,
      EditableTextState editableTextState,
      ) {
    final List<ContextMenuButtonItem> buttonItems = List.from(
      editableTextState.contextMenuButtonItems,
    );

    // Only add "Paste Image" if we have a callback for pasted attachments
    if (widget.onPastedAttachments == null) {
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: editableTextState.contextMenuAnchors,
        buttonItems: buttonItems,
      );
    }

    return FutureBuilder<Uint8List?>(
      future: _clipboardService.getClipboardImage(),
      builder: (context, snapshot) {
        final imageData = snapshot.data;
        final hasImage = imageData != null && imageData.isNotEmpty;

        if (hasImage) {
          // Avoid duplicating any platform or framework-provided image paste
          // action that is already present in the button list.
          final pasteImageLabel =
              AppLocalizations.of(context)?.pasteImage ?? 'Paste Image';
          final alreadyHasPasteImage = buttonItems.any(
                (item) =>
            item.label != null &&
                item.label!.toLowerCase().contains('image'),
          );

          if (!alreadyHasPasteImage) {
            // Find the index of the standard Paste button to insert after it
            final pasteIndex = buttonItems.indexWhere(
                  (item) => item.type == ContextMenuButtonType.paste,
            );

            // Capture imageData in closure to avoid re-reading clipboard
            final pasteImageItem = ContextMenuButtonItem(
              label: pasteImageLabel,
              onPressed: () {
                // Close the context menu first
                ContextMenuController.removeAny();
                // Use the captured imageData directly
                _handleClipboardPasteWithData(imageData);
              },
            );

            // Insert after Paste if found, otherwise add at the end
            if (pasteIndex >= 0) {
              buttonItems.insert(pasteIndex + 1, pasteImageItem);
            } else {
              buttonItems.add(pasteImageItem);
            }
          }
        }

        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: editableTextState.contextMenuAnchors,
          buttonItems: buttonItems,
        );
      },
    );
  }

  void _insertNewline() {
    final text = _controller.text;
    TextSelection sel = _controller.selection;
    final int start = sel.isValid ? sel.start : text.length;
    final int end = sel.isValid ? sel.end : text.length;
    final String before = text.substring(0, start);
    final String after = text.substring(end);
    final String updated = '$before\n$after';
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: before.length + 1),
      composing: TextRange.empty,
    );
    // Ensure field stays focused
    _ensureFocusedIfEnabled();
  }

  static final RegExp _promptCommandBoundary = RegExp(r'\s');

  void _handleComposerChanged() {
    if (!mounted || _isDeactivated) return;
    _lastEditTime = DateTime.now();

    final String text = _controller.text;
    final TextSelection selection = _controller.selection;
    final bool hasText = text.trim().isNotEmpty;
    // Consider multiline if text contains newlines or exceeds ~50 chars
    final bool isMultiline = text.contains('\n') || text.length > 50;
    // Show the expand button when content is tall enough
    // (~4 lines: 3+ explicit newlines or ~160 wrapped chars).
    final bool showExpand =
        isMultiline && (text.split('\n').length >= 4 || text.length > 160);
    final PromptCommandMatch? match = _resolvePromptCommand(
      text,
      selection,
      widget.enabled,
    );
    final bool shouldShow = match != null;
    final bool wasShowing = _showPromptOverlay;
    final String previousCommand = _currentPromptCommand;

    bool needsUpdate =
        hasText != _hasText ||
            isMultiline != _isMultiline ||
            shouldShow != _showPromptOverlay ||
            showExpand != _showExpandButton;

    if (!needsUpdate) {
      if (match != null) {
        final TextRange? range = _currentPromptRange;
        needsUpdate =
            previousCommand != match.command ||
                range == null ||
                range.start != match.start ||
                range.end != match.end;
      } else {
        needsUpdate =
            _currentPromptCommand.isNotEmpty || _currentPromptRange != null;
      }
    }

    if (!needsUpdate) return;

    setState(() {
      _hasText = hasText;
      _isMultiline = isMultiline;
      if (!isMultiline) {
        _showExpandButton = false;
      } else {
        _showExpandButton = showExpand;
      }
      if (match != null) {
        if (previousCommand != match.command) {
          _promptSelectionIndex = 0;
        }
        _currentPromptCommand = match.command;
        _currentPromptRange = TextRange(start: match.start, end: match.end);
        _showPromptOverlay = true;
      } else {
        _currentPromptCommand = '';
        _currentPromptRange = null;
        _promptSelectionIndex = 0;
        _showPromptOverlay = false;
      }
    });

    if (!wasShowing && shouldShow) {
      // Trigger data fetch lazily when overlay first appears.
      if (_currentPromptCommand.startsWith('/')) {
        ref.read(promptsListProvider.future);
      } else if (_currentPromptCommand.startsWith('@')) {
        ref.read(modelsProvider.future);
      }
    }
  }

  PromptCommandMatch? _resolvePromptCommand(
      String text,
      TextSelection selection,
      bool enabled,
      ) {
    if (!enabled) return null;
    if (!selection.isValid || !selection.isCollapsed) return null;

    final int cursor = selection.start;
    if (cursor < 0 || cursor > text.length) return null;
    if (cursor == 0) return null;

    int start = cursor;
    while (start > 0) {
      final String previous = text.substring(start - 1, start);
      if (_promptCommandBoundary.hasMatch(previous)) {
        break;
      }
      start--;
    }

    final String candidate = text.substring(start, cursor);
    if (candidate.isEmpty ||
        !(candidate.startsWith('/') ||
            candidate.startsWith('#') ||
            candidate.startsWith('@'))) {
      return null;
    }

    return PromptCommandMatch(command: candidate, start: start, end: cursor);
  }

  List<Prompt> _filterPrompts(List<Prompt> prompts) {
    if (prompts.isEmpty) return const <Prompt>[];
    final String query = _currentPromptCommand.toLowerCase().trim();
    // Strip leading '/' prefix so we can match prompt commands (e.g., "help")
    final String searchQuery = query.startsWith('/')
        ? query.substring(1)
        : query;

    final List<Prompt> filtered =
    prompts
        .where(
          (prompt) =>
      prompt.command.toLowerCase().contains(searchQuery) &&
          prompt.content.isNotEmpty,
    )
        .toList()
      ..sort((a, b) {
        final int titleCompare = a.title.toLowerCase().compareTo(
          b.title.toLowerCase(),
        );
        if (titleCompare != 0) return titleCompare;
        return a.command.toLowerCase().compareTo(b.command.toLowerCase());
      });

    return filtered;
  }

  List<Model> _filterModels(List<Model> models) {
    if (models.isEmpty) return const <Model>[];
    final String query = _currentPromptCommand.toLowerCase().trim();
    final String searchQuery = query.startsWith('@')
        ? query.substring(1)
        : query;

    if (searchQuery.isEmpty) return models;

    return models
        .where(
          (m) =>
      m.name.toLowerCase().contains(searchQuery) ||
          m.id.toLowerCase().contains(searchQuery),
    )
        .toList();
  }

  void _applyModel(Model model) {
    final TextRange? range = _currentPromptRange;
    if (range == null) return;

    // Replace the @query with @ModelName (keep it visible like OpenWebUI).
    final String text = _controller.text;
    final String before = text.substring(0, range.start);
    final String after = text.substring(range.end);
    final String mention = '@${model.name} ';
    final String newText = '$before$mention$after';
    final int newCursor = before.length + mention.length;

    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );

    // Track the mention range for styled rendering
    // (exclude trailing space) and store the model ID
    // so we can convert to OpenWebUI wire format on send.
    _controller.addMention(
      range.start,
      range.start + mention.trimRight().length,
      idType: 'M',
      id: model.id,
      label: model.name,
    );

    // Switch to the selected model.
    ref.read(selectedModelProvider.notifier).set(model);

    setState(() {
      _hasText = newText.trim().isNotEmpty;
      _showPromptOverlay = false;
      _currentPromptCommand = '';
      _currentPromptRange = null;
      _promptSelectionIndex = 0;
    });
  }

  void _movePromptSelection(int delta) {
    if (_currentPromptCommand.startsWith('#')) {
      // Only a single option in knowledge overlay; nothing to move.
      return;
    }

    // Determine filtered list length based on trigger type.
    final int filteredLength;
    if (_currentPromptCommand.startsWith('@')) {
      final List<Model>? models = ref.read(modelsProvider).value;
      if (models == null || models.isEmpty) return;
      filteredLength = _filterModels(models).length;
    } else {
      final List<Prompt>? prompts = ref.read(promptsListProvider).value;
      if (prompts == null || prompts.isEmpty) return;
      filteredLength = _filterPrompts(prompts).length;
    }
    if (filteredLength == 0) return;

    int newIndex = _promptSelectionIndex + delta;
    if (newIndex < 0) {
      newIndex = 0;
    } else if (newIndex >= filteredLength) {
      newIndex = filteredLength - 1;
    }
    if (newIndex == _promptSelectionIndex) return;

    setState(() {
      _promptSelectionIndex = newIndex;
    });
  }

  void _confirmPromptSelection() {
    if (_currentPromptCommand.startsWith('#')) {
      _openKnowledgePicker();
      return;
    }

    if (_currentPromptCommand.startsWith('@')) {
      final List<Model>? models = ref.read(modelsProvider).value;
      if (models == null || models.isEmpty) return;
      final List<Model> filtered = _filterModels(models);
      if (filtered.isEmpty) return;
      int index = _promptSelectionIndex.clamp(0, filtered.length - 1);
      _applyModel(filtered[index]);
      return;
    }

    final AsyncValue<List<Prompt>> promptsAsync = ref.read(promptsListProvider);
    final List<Prompt>? prompts = promptsAsync.value;
    if (prompts == null || prompts.isEmpty) return;

    final List<Prompt> filtered = _filterPrompts(prompts);
    if (filtered.isEmpty) return;

    int index = _promptSelectionIndex;
    if (index < 0) {
      index = 0;
    } else if (index >= filtered.length) {
      index = filtered.length - 1;
    }
    _applyPrompt(filtered[index]);
  }

  void _applyPrompt(Prompt prompt) {
    final TextRange? range = _currentPromptRange;
    if (range == null) return;

    // Check if the prompt has variables that need processing
    const parser = PromptVariableParser();
    if (parser.hasVariables(prompt.content)) {
      _processPromptWithVariables(prompt, range);
    } else {
      _insertPromptContent(prompt.content, range);
    }
  }

  Future<void> _processPromptWithVariables(
      Prompt prompt,
      TextRange range,
      ) async {
    // Hide overlay first
    setState(() {
      _showPromptOverlay = false;
      _currentPromptCommand = '';
      _currentPromptRange = null;
      _promptSelectionIndex = 0;
    });

    // Get user info for system variables
    final authUser = ref.read(currentUserProvider2);
    final userAsync = ref.read(currentUserProvider);
    final user = userAsync.maybeWhen(
      data: (value) => value ?? authUser,
      orElse: () => authUser,
    );
    final locale = Localizations.localeOf(context);

    // Create the processor with system variable context
    const parser = PromptVariableParser();
    final systemResolver = SystemVariableResolver(
      userName: user?.name ?? user?.email,
      userLanguage: locale.languageCode,
      // userLocation requires permission - left empty for now
    );
    final processor = PromptProcessor(
      parser: parser,
      systemResolver: systemResolver,
    );

    // Process system variables first
    final processed = await processor.process(prompt.content);
    if (!mounted) return;

    String finalContent = processed.content;

    // If there are user input variables, show the dialog
    if (processed.needsUserInput) {
      final values = await PromptVariableDialog.show(
        context,
        variables: processed.userInputVariables,
        promptTitle: prompt.title,
      );

      if (values == null || !mounted) {
        // User cancelled - restore focus
        _ensureFocusedIfEnabled();
        return;
      }

      // Apply user-provided values
      finalContent = processor.applyUserValues(finalContent, values);
    }

    // Insert the fully processed content
    _insertPromptContent(finalContent, range);
  }

  void _insertPromptContent(String content, TextRange range) {
    final String text = _controller.text;
    final String before = text.substring(0, range.start);
    final String after = text.substring(range.end);
    final int caret = before.length + content.length;

    _controller.value = TextEditingValue(
      text: '$before$content$after',
      selection: TextSelection.collapsed(offset: caret),
      composing: TextRange.empty,
    );

    _ensureFocusedIfEnabled();

    setState(() {
      _showPromptOverlay = false;
      _currentPromptCommand = '';
      _currentPromptRange = null;
      _promptSelectionIndex = 0;
    });
  }

  void _hidePromptOverlay() {
    if (!_showPromptOverlay) return;
    setState(() {
      _showPromptOverlay = false;
      _currentPromptCommand = '';
      _currentPromptRange = null;
      _promptSelectionIndex = 0;
    });
  }

  Future<void> _openKnowledgePicker() async {
    _hidePromptOverlay();

    // Ensure bases are loaded in the centralized cache
    final cacheNotifier = ref.read(knowledgeCacheProvider.notifier);
    await cacheNotifier.ensureBases();
    if (!mounted) return;

    // Track selected base ID outside the builder so it persists across rebuilds
    String? selectedBaseId;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (modalContext) {
        return ModalSheetSafeArea(
          // Use StatefulBuilder to manage selectedBaseId locally so that
          // selecting a knowledge base triggers a proper rebuild.
          child: StatefulBuilder(
            builder: (statefulContext, setModalState) {
              return Consumer(
                builder: (innerContext, innerRef, _) {
                  final cacheState = innerRef.watch(knowledgeCacheProvider);
                  final bases = cacheState.bases;
                  final itemsMap = cacheState.items;
                  final items = selectedBaseId != null
                      ? itemsMap[selectedBaseId] ?? const <KnowledgeBaseItem>[]
                      : const <KnowledgeBaseItem>[];
                  final loading =
                      cacheState.isLoading ||
                          (selectedBaseId != null &&
                              !itemsMap.containsKey(selectedBaseId));

                  Future<void> loadItems(KnowledgeBase base) async {
                    setModalState(() {
                      selectedBaseId = base.id;
                    });
                    await innerRef
                        .read(knowledgeCacheProvider.notifier)
                        .fetchItemsForBase(base.id);
                  }

                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: innerContext.qonduitTheme.surfaceBackground,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(AppBorderRadius.modal),
                      ),
                      boxShadow: QonduitShadows.modal(innerContext),
                    ),
                    child: SizedBox(
                      height: MediaQuery.of(innerContext).size.height * 0.6,
                      child: Row(
                        children: [
                          Expanded(
                            flex: 1,
                            child: ListView.builder(
                              itemCount: bases.length,
                              itemBuilder: (context, index) {
                                final base = bases[index];
                                final isSelected = selectedBaseId == base.id;
                                return AdaptiveListTile(
                                  selected: isSelected,
                                  title: Text(base.name),
                                  onTap: () => loadItems(base),
                                );
                              },
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            flex: 2,
                            child: loading
                                ? const Center(
                              child: CircularProgressIndicator(),
                            )
                                : ListView.builder(
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                final item = items[index];
                                final KnowledgeBase? selectedBase =
                                bases.isEmpty
                                    ? null
                                    : bases.firstWhere(
                                      (b) => b.id == selectedBaseId,
                                  orElse: () => bases.first,
                                );
                                return AdaptiveListTile(
                                  title: Text(
                                    item.title ??
                                        item.metadata['name']
                                            ?.toString() ??
                                        'Document',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    item.metadata['source']?.toString() ??
                                        item.content,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    innerRef
                                        .read(
                                      contextAttachmentsProvider
                                          .notifier,
                                    )
                                        .addKnowledge(
                                      displayName:
                                      item.title ??
                                          item.metadata['name']
                                              ?.toString() ??
                                          'Document',
                                      fileId: item.id,
                                      collectionName:
                                      selectedBase?.name ??
                                          'Unknown',
                                      url: item.metadata['source']
                                          ?.toString(),
                                    );
                                    if (modalContext.mounted) {
                                      Navigator.of(modalContext).pop();
                                    }
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  /// Returns the correct overlay widget for the current trigger character.
  Widget _buildActiveOverlay() {
    if (_currentPromptCommand.startsWith('#')) {
      return _buildKnowledgeOverlay(
        context,
        context.qonduitTheme.cardBackground,
        context.qonduitTheme.cardBorder.withValues(
          alpha: Theme.of(context).brightness == Brightness.dark ? 0.6 : 0.4,
        ),
      );
    }
    if (_currentPromptCommand.startsWith('@')) {
      return ModelSuggestionOverlay(
        filteredModels: _filterModels,
        selectionIndex: _promptSelectionIndex,
        onModelSelected: _applyModel,
      );
    }
    return PromptSuggestionOverlay(
      filteredPrompts: _filterPrompts,
      selectionIndex: _promptSelectionIndex,
      onPromptSelected: _applyPrompt,
    );
  }

  Widget _buildKnowledgeOverlay(
      BuildContext context,
      Color overlayColor,
      Color borderColor,
      ) {
    return Container(
      decoration: BoxDecoration(
        color: overlayColor,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: borderColor, width: BorderWidth.thin),
        boxShadow: [
          BoxShadow(
            color: context.qonduitTheme.cardShadow.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? 0.28
                  : 0.16,
            ),
            blurRadius: 22,
            offset: const Offset(0, 8),
            spreadRadius: -4,
          ),
        ],
      ),
      child: AdaptiveListTile(
        title: const Text('Browse knowledge base'),
        subtitle: const Text('Press Enter to pick a document'),
        leading: const Icon(Icons.folder_outlined),
        onTap: _openKnowledgePicker,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(composerAutofocusEnabledProvider, (previous, next) {
      if ((previous ?? true) && !next && _focusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _isDeactivated) return;
          _focusNode.unfocus();
        });
      }
    });

    ref.listen<String?>(prefilledInputTextProvider, (previous, next) {
      final incoming = next?.trim();
      if (incoming == null || incoming.isEmpty) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDeactivated) return;
        _controller.text = incoming;
        _controller.selection = TextSelection.collapsed(
          offset: incoming.length,
        );
        try {
          ref.read(prefilledInputTextProvider.notifier).clear();
        } catch (_) {}
      });
    });

    // Use dedicated streaming provider to avoid rebuilding on every message change
    final isGenerating = ref.watch(isChatStreamingProvider);
    final stopGeneration = ref.read(stopGenerationProvider);

    // Check if file uploads are in progress or complete
    final attachedFiles = ref.watch(attachedFilesProvider);
    final hasUploadsInProgress = attachedFiles.any(
          (f) =>
      f.status == FileUploadStatus.uploading ||
          f.status == FileUploadStatus.pending,
    );
    final allUploadsComplete =
        attachedFiles.isEmpty ||
            attachedFiles.every((f) => f.status == FileUploadStatus.completed);

    final webSearchEnabled = ref.watch(webSearchEnabledProvider);
    final webSearchAvailable = ref.watch(webSearchAvailableProvider);
    final imageGenEnabled = ref.watch(imageGenerationEnabledProvider);
    final imageGenAvailable = ref.watch(imageGenerationAvailableProvider);
    final selectedQuickPills = ref.watch(
      appSettingsProvider.select((s) => s.quickPills),
    );
    final sendOnEnter = ref.watch(
      appSettingsProvider.select((s) => s.sendOnEnter),
    );
    final toolsAsync = ref.watch(toolsListProvider);
    final List<Tool> availableTools = toolsAsync.maybeWhen<List<Tool>>(
      data: (t) => t,
      orElse: () => const <Tool>[],
    );
    final bool showWebPill = selectedQuickPills.contains('web');
    final bool showImagePillPref = selectedQuickPills.contains('image');
    final voiceAvailableAsync = ref.watch(voiceInputAvailableProvider);
    final bool voiceAvailable = voiceAvailableAsync.maybeWhen(
      data: (v) => v,
      orElse: () => false,
    );
    final selectedToolIds = ref.watch(selectedToolIdsProvider);
    final selectedFilterIds = ref.watch(selectedFilterIdsProvider);

    // Get filters from the selected model for quick pills
    final selectedModel = ref.watch(selectedModelProvider);
    final availableFilters = selectedModel?.filters ?? const [];

    final focusTick = ref.watch(inputFocusTriggerProvider);
    final autofocusEnabled = ref.watch(composerAutofocusEnabledProvider);
    if (autofocusEnabled && focusTick != _lastHandledFocusTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDeactivated) return;
        _ensureFocusedIfEnabled();
        _lastHandledFocusTick = focusTick;
      });
    }

    final Brightness brightness = Theme.of(context).brightness;

    // Keep mention highlight colors in sync with the theme.
    final mentionColor = context.qonduitTheme.buttonPrimary;
    _controller.mentionColor = mentionColor;
    _controller.mentionBackground = mentionColor.withValues(alpha: 0.12);

    final bool hasComposerFocus = _focusNode.hasFocus;
    final bool isActive = hasComposerFocus || _hasText;
    final bool useGlassColors = !kIsWeb && Platform.isIOS;
    final Color placeholderColor = useGlassColors
        ? GlassColors.secondaryLabel(context)
        : context.qonduitTheme.textSecondary.withValues(alpha: 0.5);
    final Color placeholderBase = placeholderColor;
    final Color placeholderFocused = placeholderColor;
    final List<Widget> quickPills = <Widget>[];

    for (final id in selectedQuickPills) {
      if (id == 'web' && showWebPill && webSearchAvailable) {
        final String label = AppLocalizations.of(context)!.web;
        final IconData icon = Platform.isIOS
            ? CupertinoIcons.search
            : Icons.search;
        void handleTap() {
          final notifier = ref.read(webSearchEnabledProvider.notifier);
          notifier.set(!webSearchEnabled);
        }

        quickPills.add(
          _buildPillButton(
            icon: icon,
            label: label,
            isActive: webSearchEnabled,
            dense: true,
            onTap: widget.enabled && !_isRecording ? handleTap : null,
          ),
        );
      } else if (id == 'image' && showImagePillPref && imageGenAvailable) {
        final String label = AppLocalizations.of(context)!.imageGen;
        final IconData icon = Platform.isIOS
            ? CupertinoIcons.photo
            : Icons.image;
        void handleTap() {
          final notifier = ref.read(imageGenerationEnabledProvider.notifier);
          notifier.set(!imageGenEnabled);
        }

        quickPills.add(
          _buildPillButton(
            icon: icon,
            label: label,
            isActive: imageGenEnabled,
            dense: true,
            onTap: widget.enabled && !_isRecording ? handleTap : null,
          ),
        );
      } else if (id.startsWith('filter:')) {
        // Handle filter quick pills
        final filterId = id.substring(7); // Remove 'filter:' prefix
        ToggleFilter? filter;
        for (final f in availableFilters) {
          if (f.id == filterId) {
            filter = f;
            break;
          }
        }
        if (filter != null) {
          final bool isSelected = selectedFilterIds.contains(filterId);
          final String label = filter.name;
          final IconData icon = Platform.isIOS
              ? CupertinoIcons.sparkles
              : Icons.auto_awesome;

          void handleTap() {
            ref.read(selectedFilterIdsProvider.notifier).toggle(filterId);
          }

          quickPills.add(
            _buildPillButton(
              icon: icon,
              label: label,
              isActive: isSelected,
              dense: true,
              onTap: widget.enabled && !_isRecording ? handleTap : null,
              iconUrl: filter.icon,
            ),
          );
        }
      } else {
        // Handle tool quick pills
        Tool? tool;
        for (final t in availableTools) {
          if (t.id == id) {
            tool = t;
            break;
          }
        }
        if (tool != null) {
          final bool isSelected = selectedToolIds.contains(id);
          final String label = tool.name;
          final IconData icon = Platform.isIOS
              ? CupertinoIcons.wrench
              : Icons.build;

          void handleTap() {
            final current = List<String>.from(selectedToolIds);
            if (current.contains(id)) {
              current.remove(id);
            } else {
              current.add(id);
            }
            ref.read(selectedToolIdsProvider.notifier).set(current);
          }

          quickPills.add(
            _buildPillButton(
              icon: icon,
              label: label,
              isActive: isSelected,
              dense: true,
              onTap: widget.enabled && !_isRecording ? handleTap : null,
            ),
          );
        }
      }
    }

    final bool showCompactComposer = quickPills.isEmpty;

    // Keep iOS 26 single-line composer as capsule.
    // Switch multiline to rounded rectangle to avoid oval morphing.
    const double multilineRadius = AppBorderRadius.large;
    final double compactRadius = _useIOS26NativeControls
        ? (_isMultiline ? multilineRadius : AppBorderRadius.round)
        : (_isMultiline ? AppBorderRadius.xl : AppBorderRadius.round);
    final double expandedRadius = _useIOS26NativeControls
        ? AppBorderRadius.xl
        : _composerRadius;
    final BorderRadius shellRadius = BorderRadius.circular(
      showCompactComposer ? compactRadius : expandedRadius,
    );

    final List<Widget> composerChildren = <Widget>[
      if (_showPromptOverlay)
        Padding(
          key: const ValueKey('prompt-overlay'),
          padding: const EdgeInsets.fromLTRB(
            Spacing.sm,
            0,
            Spacing.sm,
            Spacing.xs,
          ),
          child: _buildActiveOverlay(),
        ),
      if (!showCompactComposer) ...[
        Padding(
          key: const ValueKey('composer-expanded-input'),
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.sm,
            Spacing.md,
            Spacing.sm,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: _buildComposerTextField(
                      brightness: brightness,
                      sendOnEnter: sendOnEnter,
                      voiceAvailable: voiceAvailable,
                      isGenerating: isGenerating,
                      allUploadsComplete: allUploadsComplete,
                      placeholderBase: placeholderBase,
                      placeholderFocused: placeholderFocused,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.xs,
                      ),
                      isActive: isActive,
                    ),
                  ),
                ],
              ),
              Positioned(
                top: Spacing.xs,
                right: Spacing.xs,
                child: AnimatedOpacity(
                  opacity: (_showExpandButton && !_expandModalOpen) ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 160),
                  child: IgnorePointer(
                    ignoring: !_showExpandButton || _expandModalOpen,
                    child: _buildExpandButton(_showExpandTextModal),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          key: const ValueKey('composer-expanded-buttons'),
          padding: const EdgeInsets.fromLTRB(
            Spacing.inputPadding,
            0,
            Spacing.inputPadding,
            Spacing.sm,
          ),
          child: Row(
            children: [
              _buildOverflowButton(
                tooltip: AppLocalizations.of(context)!.more,
                webSearchActive: webSearchEnabled,
                imageGenerationActive: imageGenEnabled,
                toolsActive: selectedToolIds.isNotEmpty,
                filtersActive: selectedFilterIds.isNotEmpty,
                dense: true,
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: ClipRect(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: _withHorizontalSpacing(quickPills, Spacing.xxs),
                    ),
                  ),
                ),
              ),
              if (!_hasText && voiceAvailable && !isGenerating) ...[
                const SizedBox(width: Spacing.xs),
                _buildInlineMicAction(voiceAvailable),
              ],
              const SizedBox(width: Spacing.xs),
              _buildPrimaryButton(
                _hasText,
                isGenerating,
                stopGeneration,
                voiceAvailable,
                allUploadsComplete,
                hasUploadsInProgress,
                dense: true,
              ),
            ],
          ),
        ),
      ],
    ];

    // For compact mode, render text field shell with floating buttons on sides
    if (showCompactComposer) {
      final textFieldContent = Container(
        padding: EdgeInsets.fromLTRB(
          Spacing.md,
          0,
          Spacing.md,
          _isMultiline ? Spacing.sm : 0,
        ),
        constraints: const BoxConstraints(minHeight: TouchTarget.input),
        alignment: Alignment.center,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              crossAxisAlignment: _isMultiline
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _buildComposerTextField(
                    brightness: brightness,
                    sendOnEnter: sendOnEnter,
                    voiceAvailable: voiceAvailable,
                    isGenerating: isGenerating,
                    allUploadsComplete: allUploadsComplete,
                    placeholderBase: placeholderBase,
                    placeholderFocused: placeholderFocused,
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: Spacing.xs,
                    ),
                    isActive: isActive,
                  ),
                ),
                if (!_hasText && voiceAvailable && !isGenerating) ...[
                  const SizedBox(width: Spacing.xs),
                  // Wrap in the same height as the dense primary button so
                  // the mic icon's visual center aligns with the button when
                  // bottom-aligned in the multiline (crossAxisAlignment.end)
                  // layout.
                  SizedBox(
                    height: 36.0,
                    child: Center(child: _buildInlineMicAction(voiceAvailable)),
                  ),
                ],
                const SizedBox(width: Spacing.xs),
                _buildPrimaryButton(
                  _hasText,
                  isGenerating,
                  stopGeneration,
                  voiceAvailable,
                  allUploadsComplete,
                  hasUploadsInProgress,
                  dense: true,
                ),
              ],
            ),
            Positioned(
              top: Spacing.xs,
              right: 0,
              child: AnimatedOpacity(
                opacity: (_showExpandButton && !_expandModalOpen) ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 160),
                child: IgnorePointer(
                  ignoring: !_showExpandButton || _expandModalOpen,
                  child: _buildExpandButton(_showExpandTextModal),
                ),
              ),
            ),
          ],
        ),
      );

      // Use AdaptiveButton glass for single-line compact input.
      // Multiline uses AdaptiveBlurView for dynamic height.
      final bool useNativeCompactGlass =
          _useIOS26NativeControls && !_isMultiline;
      final Widget textFieldShell = useNativeCompactGlass
          ? LayoutBuilder(
        key: const ValueKey('compact-native-glass'),
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.of(context).size.width * 0.58;

          return ClipRRect(
            borderRadius: shellRadius,
            child: SizedBox(
              height: TouchTarget.input,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AdaptiveButton.child(
                        onPressed: () {},
                        enabled: true,
                        style: AdaptiveButtonStyle.glass,
                        size: AdaptiveButtonSize.large,
                        minSize: Size(width, TouchTarget.input),
                        useSmoothRectangleBorder: false,
                        child: const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  textFieldContent,
                ],
              ),
            ),
          );
        },
      )
          : _buildComposerShell(
        key: const ValueKey('compact-glass-fallback'),
        borderRadius: shellRadius,
        child: textFieldContent,
      );

      final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
      return Padding(
        padding: EdgeInsets.fromLTRB(
          Spacing.screenPadding,
          0,
          Spacing.screenPadding,
          bottomPadding + Spacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Show prompt overlay above the compact input row when active
            if (_showPromptOverlay)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.xs),
                child: _buildActiveOverlay(),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _buildOverflowButton(
                  tooltip: AppLocalizations.of(context)!.more,
                  webSearchActive: webSearchEnabled,
                  imageGenerationActive: imageGenEnabled,
                  toolsActive: selectedToolIds.isNotEmpty,
                  filtersActive: selectedFilterIds.isNotEmpty,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: _wrapIosSurfaceShadow(
                    textFieldShell,
                    borderRadius: shellRadius,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // For expanded mode with quick pills, use the full shell.
    final shellContent = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.4,
      ),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: RepaintBoundary(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: composerChildren,
            ),
          ),
        ),
      ),
    );

    final Widget shell = _wrapIosSurfaceShadow(
      _buildComposerShell(borderRadius: shellRadius, child: shellContent),
      borderRadius: shellRadius,
    );

    // Wrap with padding for floating effect, accounting for safe area
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.screenPadding,
        0,
        Spacing.screenPadding,
        bottomPadding + Spacing.md,
      ),
      child: shell,
    );
  }

  // (Removed legacy _buildVoiceButton; mic functionality moved to primary button)

  List<Widget> _withHorizontalSpacing(List<Widget> children, double gap) {
    if (children.length <= 1) {
      return List<Widget>.from(children);
    }
    final result = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      result.add(children[i]);
      if (i != children.length - 1) {
        result.add(SizedBox(width: gap));
      }
    }
    return result;
  }

  Widget _buildComposerTextField({
    required Brightness brightness,
    required bool sendOnEnter,
    required bool voiceAvailable,
    required bool isGenerating,
    required bool allUploadsComplete,
    required Color placeholderBase,
    required Color placeholderFocused,
    required EdgeInsetsGeometry contentPadding,
    required bool isActive,
  }) {
    return GestureDetector(
      key: _textFieldKey,
      behavior: HitTestBehavior.opaque,
      // Exclude from semantics so screen readers interact directly with the
      // TextField, which provides its own accessibility via hintText.
      excludeFromSemantics: true,
      onTap: () {
        if (!widget.enabled) return;
        // Explicit user intent to focus: re-enable autofocus and focus
        try {
          ref.read(composerAutofocusEnabledProvider.notifier).set(true);
        } catch (_) {}
        _ensureFocusedIfEnabled();
      },
      child: Shortcuts(
        shortcuts: () {
          final map = <LogicalKeySet, Intent>{
            LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.enter):
            const SendMessageIntent(),
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.enter):
            const SendMessageIntent(),
          };
          if (sendOnEnter) {
            map[LogicalKeySet(LogicalKeyboardKey.enter)] =
            const SendMessageIntent();
            map[LogicalKeySet(
              LogicalKeyboardKey.shift,
              LogicalKeyboardKey.enter,
            )] =
            const InsertNewlineIntent();
          }
          if (_showPromptOverlay) {
            map[LogicalKeySet(LogicalKeyboardKey.arrowDown)] =
            const SelectNextPromptIntent();
            map[LogicalKeySet(LogicalKeyboardKey.arrowUp)] =
            const SelectPreviousPromptIntent();
            map[LogicalKeySet(LogicalKeyboardKey.escape)] =
            const DismissPromptIntent();
          }
          return map;
        }(),
        child: Actions(
          actions: <Type, Action<Intent>>{
            SendMessageIntent: CallbackAction<SendMessageIntent>(
              onInvoke: (intent) {
                if (_showPromptOverlay) {
                  _confirmPromptSelection();
                  return null;
                }
                _sendMessage();
                return null;
              },
            ),
            InsertNewlineIntent: CallbackAction<InsertNewlineIntent>(
              onInvoke: (intent) {
                _insertNewline();
                return null;
              },
            ),
            SelectNextPromptIntent: CallbackAction<SelectNextPromptIntent>(
              onInvoke: (intent) {
                _movePromptSelection(1);
                return null;
              },
            ),
            SelectPreviousPromptIntent:
            CallbackAction<SelectPreviousPromptIntent>(
              onInvoke: (intent) {
                _movePromptSelection(-1);
                return null;
              },
            ),
            DismissPromptIntent: CallbackAction<DismissPromptIntent>(
              onInvoke: (intent) {
                _hidePromptOverlay();
                return null;
              },
            ),
          },
          child: Builder(
            builder: (context) {
              final double factor = isActive ? 1.0 : 0.0;
              final Color animatedPlaceholder = Color.lerp(
                placeholderBase,
                placeholderFocused,
                factor,
              )!;
              final textLabel = (!kIsWeb && Platform.isIOS)
                  ? GlassColors.label(context)
                  : context.qonduitTheme.inputText;
              final Color animatedTextColor = Color.lerp(
                textLabel.withValues(alpha: 0.88),
                textLabel,
                factor,
              )!;

              final FontWeight recordingWeight = _isRecording
                  ? FontWeight.w500
                  : FontWeight.w400;
              final TextStyle baseChatStyle = AppTypography.chatMessageStyle;

              // IMPORTANT: Always use TextInputAction.newline for multiline
              // chat input. Using TextInputAction.send causes issues with
              // Braille keyboards (like Advanced Braille Keyboard) where
              // the "confirm" action is used to commit characters, not to
              // send messages. The send-on-enter functionality is handled
              // by keyboard shortcuts (Enter key) instead.
              if (!kIsWeb && Platform.isIOS) {
                return CupertinoTextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  placeholder:
                  widget.placeholder ??
                      AppLocalizations.of(context)!.messageHintText,
                  placeholderStyle: baseChatStyle.copyWith(
                    color: animatedPlaceholder,
                    fontWeight: recordingWeight,
                    fontStyle: _isRecording
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                  enabled: widget.enabled,
                  autofocus: false,
                  minLines: 1,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.center,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.newline,
                  autofillHints: const <String>[],
                  showCursor: true,
                  scrollPadding: const EdgeInsets.only(bottom: 80),
                  keyboardAppearance: brightness,
                  cursorColor: animatedTextColor,
                  style: baseChatStyle.copyWith(
                    color: animatedTextColor,
                    fontStyle: _isRecording
                        ? FontStyle.italic
                        : FontStyle.normal,
                    fontWeight: recordingWeight,
                  ),
                  contentInsertionConfiguration: ContentInsertionConfiguration(
                    allowedMimeTypes: ClipboardAttachmentService
                        .supportedImageMimeTypes
                        .toList(),
                    onContentInserted: _handleContentInserted,
                  ),
                  // Transparent decoration — the glass container provides
                  // the visual frame.
                  decoration: const BoxDecoration(),
                  padding: contentPadding,
                  contextMenuBuilder: (context, editableTextState) {
                    return _buildIosContextMenu(context, editableTextState);
                  },
                  onSubmitted: (_) {},
                  onTap: () {
                    if (!widget.enabled) return;
                    _ensureFocusedIfEnabled();
                  },
                );
              }
              return TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                autofocus: false,
                minLines: 1,
                maxLines: null,
                textAlignVertical: TextAlignVertical.center,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.newline,
                autofillHints: const <String>[],
                showCursor: true,
                scrollPadding: const EdgeInsets.only(bottom: 80),
                keyboardAppearance: brightness,
                cursorColor: animatedTextColor,
                style: baseChatStyle.copyWith(
                  color: animatedTextColor,
                  fontStyle: _isRecording ? FontStyle.italic : FontStyle.normal,
                  fontWeight: recordingWeight,
                ),
                decoration: context.qonduitInputStyles
                    .borderless(
                  hint:
                  widget.placeholder ??
                      AppLocalizations.of(context)!.messageHintText,
                )
                    .copyWith(
                  hintStyle: baseChatStyle.copyWith(
                    color: animatedPlaceholder,
                    fontWeight: recordingWeight,
                    fontStyle: _isRecording
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                  contentPadding: contentPadding,
                  isDense: true,
                  alignLabelWithHint: true,
                ),
                // Enable pasting images and files from clipboard
                contentInsertionConfiguration: ContentInsertionConfiguration(
                  allowedMimeTypes: ClipboardAttachmentService
                      .supportedImageMimeTypes
                      .toList(),
                  onContentInserted: _handleContentInserted,
                ),
                // Custom context menu with "Paste Image" option
                contextMenuBuilder: (context, editableTextState) {
                  return _buildFallbackContextMenu(context, editableTextState);
                },
                onSubmitted: (_) {},
                onTap: () {
                  if (!widget.enabled) return;
                  _ensureFocusedIfEnabled();
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildOverflowButton({
    required String tooltip,
    required bool webSearchActive,
    required bool imageGenerationActive,
    required bool toolsActive,
    required bool filtersActive,
    bool dense = false,
  }) {
    final double buttonSize = dense ? 36.0 : TouchTarget.minimum;

    // Let the parent supply a completely custom overflow button.
    if (widget.overflowButtonBuilder != null) {
      return widget.overflowButtonBuilder!(buttonSize);
    }

    final bool enabled = widget.enabled && !_isRecording;

    Color? activeColor;
    if (webSearchActive ||
        imageGenerationActive ||
        toolsActive ||
        filtersActive) {
      activeColor = context.qonduitTheme.buttonPrimary;
    }

    final bool isActive = activeColor != null;

    final Color iconColor = !enabled
        ? context.qonduitTheme.textPrimary.withValues(alpha: Alpha.disabled)
        : isActive
        ? context.qonduitTheme.buttonPrimaryText
        : context.qonduitTheme.textPrimary.withValues(alpha: Alpha.strong);

    final IconData overflowIcon = switch ((
    webSearchActive,
    imageGenerationActive,
    toolsActive,
    filtersActive,
    )) {
      (true, _, _, _) => Platform.isIOS ? CupertinoIcons.search : Icons.search,
      (_, true, _, _) => Platform.isIOS ? CupertinoIcons.photo : Icons.image,
      (_, _, true, _) => Platform.isIOS ? CupertinoIcons.wrench : Icons.build,
      (_, _, _, true) =>
      Platform.isIOS ? CupertinoIcons.sparkles : Icons.auto_awesome,
      _ => Platform.isIOS ? CupertinoIcons.add : Icons.add,
    };

    return AdaptiveTooltip(
      message: tooltip,
      child: _buildComposerIconButton(
        onPressed: enabled
            ? () {
          HapticFeedback.selectionClick();
          _showOverflowSheet();
        }
            : null,
        size: buttonSize,
        isProminent: isActive,
        child: Icon(overflowIcon, size: IconSize.large, color: iconColor),
      ),
    );
  }

  Widget _buildExpandButton(VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xs),
        child: Icon(
          Icons.open_in_full,
          size: IconSize.large,
          color: context.qonduitTheme.textSecondary.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  Widget _buildInlineMicAction(bool voiceAvailable) {
    final bool enabledMic = widget.enabled && voiceAvailable;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabledMic
          ? () {
        HapticFeedback.selectionClick();
        _toggleVoice();
      }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
        child: Icon(
          Platform.isIOS ? CupertinoIcons.mic : Icons.mic,
          size: IconSize.large,
          color: _isRecording
              ? context.qonduitTheme.buttonPrimary
              : context.qonduitTheme.textSecondary.withValues(
            alpha: enabledMic ? Alpha.strong : Alpha.disabled,
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryButton(
      bool hasText,
      bool isGenerating,
      void Function() stopGeneration,
      bool voiceAvailable,
      bool allUploadsComplete,
      bool hasUploadsInProgress, {
        bool dense = false,
      }) {
    final double buttonSize = dense ? 36.0 : TouchTarget.minimum;

    // Don't allow sending until all uploads are complete
    final enabled =
        !isGenerating && hasText && widget.enabled && allUploadsComplete;

    // Generating -> STOP variant
    if (isGenerating) {
      return AdaptiveTooltip(
        message: AppLocalizations.of(context)!.stopGenerating,
        child: _buildComposerIconButton(
          key: const ValueKey('primary-btn-stop'),
          onPressed: () {
            HapticFeedback.lightImpact();
            stopGeneration();
          },
          size: buttonSize,
          isProminent: true,
          child: Icon(
            Platform.isIOS ? CupertinoIcons.stop_fill : Icons.stop,
            size: dense ? IconSize.large : IconSize.xl,
            color: context.qonduitTheme.buttonPrimaryText,
          ),
        ),
      );
    }

    // If there's text, render SEND variant; otherwise render VOICE CALL variant
    if (hasText) {
      final onPressed = enabled
          ? () {
        _sendMessage();
      }
          : null;
      final sendChild = hasUploadsInProgress
          ? SizedBox(
        width: IconSize.large,
        height: IconSize.large,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: context.qonduitTheme.textSecondary,
        ),
      )
          : Icon(
        CupertinoIcons.arrow_up,
        size: IconSize.large,
        color: enabled
            ? context.qonduitTheme.buttonPrimaryText
            : context.qonduitTheme.textPrimary.withValues(
          alpha: Alpha.disabled,
        ),
      );
      return AdaptiveTooltip(
        message: enabled
            ? AppLocalizations.of(context)!.sendMessage
            : AppLocalizations.of(context)!.send,
        child: _buildComposerIconButton(
          key: const ValueKey('primary-btn-send'),
          onPressed: onPressed,
          size: buttonSize,
          isProminent: true,
          child: sendChild,
        ),
      );
    }

    // VOICE CALL variant when no text is present and voice is available.
    // Otherwise fall back to a muted send button.
    if (widget.onVoiceCall != null) {
      final bool enabledVoiceCall = widget.enabled;
      return AdaptiveTooltip(
        message: 'Voice Call',
        child: _buildComposerIconButton(
          key: const ValueKey('primary-btn-voice-call'),
          onPressed: enabledVoiceCall
              ? () {
            PlatformUtils.lightHaptic();
            widget.onVoiceCall!();
          }
              : null,
          size: buttonSize,
          isProminent: true,
          child: Icon(
            Platform.isIOS ? CupertinoIcons.waveform : Icons.graphic_eq,
            size: dense ? IconSize.large : IconSize.xl,
            color: enabledVoiceCall
                ? context.qonduitTheme.buttonPrimaryText
                : context.qonduitTheme.textPrimary.withValues(
              alpha: Alpha.disabled,
            ),
          ),
        ),
      );
    }

    // Muted send button when no text and no voice call.
    return _buildComposerIconButton(
      key: const ValueKey('primary-btn-send-muted'),
      onPressed: null,
      size: buttonSize,
      isProminent: false,
      child: Icon(
        CupertinoIcons.arrow_up,
        size: IconSize.large,
        color: context.qonduitTheme.textPrimary.withValues(
          alpha: Alpha.disabled,
        ),
      ),
    );
  }

  Widget _buildPillButton({
    required IconData icon,
    required String label,
    required bool isActive,
    VoidCallback? onTap,
    String? iconUrl,
    bool dense = false,
  }) {
    final bool enabled = onTap != null;
    final theme = context.qonduitTheme;

    final Color background = isActive
        ? theme.buttonPrimary.withValues(alpha: 0.10)
        : Colors.transparent;

    final Color borderColor = isActive
        ? theme.buttonPrimary.withValues(alpha: 0.4)
        : theme.cardBorder;

    final Color textColor = isActive
        ? theme.buttonPrimary
        : theme.textSecondary.withValues(alpha: enabled ? 1.0 : Alpha.disabled);

    final Color iconColor = textColor;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppBorderRadius.round),
          onTap: onTap == null
              ? null
              : () {
            HapticFeedback.mediumImpact();
            onTap();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: dense ? Spacing.sm : Spacing.md,
              vertical: dense ? (Spacing.xs + 1) : (Spacing.sm - 2),
            ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppBorderRadius.round),
              border: Border.all(color: borderColor, width: BorderWidth.thin),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                iconUrl != null && iconUrl.isNotEmpty
                    ? SizedBox(
                  width: dense ? IconSize.small : IconSize.small + 1,
                  height: dense ? IconSize.small : IconSize.small + 1,
                  child: Image.network(
                    iconUrl,
                    width: dense ? IconSize.small : IconSize.small + 1,
                    height: dense ? IconSize.small : IconSize.small + 1,
                    color: iconUrl.endsWith('.svg') ? iconColor : null,
                    colorBlendMode: BlendMode.srcIn,
                    errorBuilder: (_, _, _) => Icon(
                      icon,
                      size: dense ? IconSize.small : IconSize.small + 1,
                      color: iconColor,
                    ),
                  ),
                )
                    : Icon(
                  icon,
                  size: dense ? IconSize.small : IconSize.small + 1,
                  color: iconColor,
                ),
                SizedBox(width: dense ? Spacing.xs : Spacing.xs + 1),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  style: AppTypography.labelStyle.copyWith(
                    color: textColor,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    fontSize: dense ? 12 : 13,
                    letterSpacing: -0.1,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a circular icon button for the composer.
  ///
  /// On iOS, uses [AdaptiveButton] with glass style for native appearance.
  /// On Android/web/desktop, uses a Material-styled circular button with
  /// theme-consistent colors matching the composer shell.
  Widget _buildComposerIconButton({
    Key? key,
    required VoidCallback? onPressed,
    required Widget child,
    required double size,
    bool isProminent = false,
    Color? color,
  }) {
    final theme = context.qonduitTheme;
    final effectiveColor = color ?? theme.buttonPrimary;

    if (!kIsWeb && Platform.isIOS) {
      return AdaptiveButton.child(
        key: key,
        onPressed: onPressed,
        enabled: onPressed != null,
        style: isProminent
            ? AdaptiveButtonStyle.prominentGlass
            : AdaptiveButtonStyle.glass,
        color: effectiveColor,
        size: size > 40 ? AdaptiveButtonSize.large : AdaptiveButtonSize.medium,
        minSize: Size(size, size),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(size),
        useSmoothRectangleBorder: false,
        child: child,
      );
    }

    final bgColor = isProminent
        ? effectiveColor
        : theme.surfaceContainerHighest;
    final borderColor = isProminent ? effectiveColor : theme.cardBorder;

    return SizedBox(
      key: key,
      width: size,
      height: size,
      child: Material(
        color: bgColor,
        shape: CircleBorder(
          side: BorderSide(color: borderColor, width: BorderWidth.thin),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Center(child: child),
        ),
      ),
    );
  }

  /// Builds the composer shell container.
  ///
  /// On iOS, uses [AdaptiveBlurView] for native glass/blur effects.
  /// On Android/web/desktop, uses a Material surface container with a
  /// subtle border for better contrast and a native look.
  Widget _buildComposerShell({
    Key? key,
    required Widget child,
    required BorderRadius borderRadius,
  }) {
    if (!kIsWeb && Platform.isIOS) {
      return AdaptiveBlurView(
        key: key,
        blurStyle: BlurStyle.systemUltraThinMaterial,
        borderRadius: borderRadius,
        child: child,
      );
    }
    final theme = context.qonduitTheme;
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: borderRadius,
        border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
      ),
      child: child,
    );
  }

  Widget _wrapIosSurfaceShadow(
      Widget child, {
        BorderRadius borderRadius = const BorderRadius.all(
          Radius.circular(AppBorderRadius.round),
        ),
      }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    if (!isLight) return child;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x18000000),
            blurRadius: 16,
            spreadRadius: -2,
            offset: Offset(0, 4),
          ),
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 4,
            spreadRadius: 0,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: child,
    );
  }

  void _showOverflowSheet() {
    HapticFeedback.selectionClick();
    final prevCanRequest = _focusNode.canRequestFocus;
    final wasFocused = _focusNode.hasFocus;
    _focusNode.canRequestFocus = false;
    try {
      FocusScope.of(context).unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ComposerOverflowSheet(
        onFileAttachment: widget.onFileAttachment,
        onImageAttachment: widget.onImageAttachment,
        onCameraCapture: widget.onCameraCapture,
        onWebAttachment: widget.onWebAttachment,
        onKnowledgeTool: widget.onKnowledgeTool,
        onCodeEditTool: widget.onCodeEditTool,
      ),
    ).whenComplete(() {
      if (mounted) {
        _focusNode.canRequestFocus = prevCanRequest;
        if (wasFocused && widget.enabled) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _ensureFocusedIfEnabled();
          });
        }
      }
    });
  }

  void _showExpandTextModal() {
    final modalController = TextEditingController(text: _controller.text);

    void syncToMain() {
      if (!mounted) return;
      if (_controller.text != modalController.text) {
        _controller.value = TextEditingValue(
          text: modalController.text,
          selection: TextSelection.collapsed(
            offset: modalController.text.length,
          ),
        );
      }
    }

    modalController.addListener(syncToMain);
    setState(() => _expandModalOpen = true);

    showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      enableDrag: true,
      useSafeArea: true,
      builder: (modalContext) => ExpandedTextEditorSheet(
        controller: modalController,
        onSend: () {
          FocusScope.of(modalContext).unfocus();
          Navigator.of(modalContext).pop(true);
        },
      ),
    ).then((shouldSend) {
      modalController.removeListener(syncToMain);
      // Defer disposal to the next frame so the modal route's widget tree
      // is fully deactivated first. Disposing here would race with
      // ExpandedTextEditorSheet.dispose() which still needs the controller,
      // and can trigger _dependents.isEmpty assertion failures when
      // MediaQuery-dependent widgets rebuild during deactivation.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        modalController.dispose();
      });
      if (mounted) setState(() => _expandModalOpen = false);
      if (shouldSend == true && mounted) _sendMessage();
    });
  }

  // --- Inline Voice Input ---
  Future<void> _toggleVoice() async {
    if (_isRecording) {
      await _stopVoice();
    } else {
      await _startVoice();
    }
  }

  Future<void> _startVoice() async {
    if (!widget.enabled) return;
    try {
      final ok = await _voiceService.initialize();
      if (!mounted) return;
      if (!ok) {
        _showVoiceUnavailable(
          AppLocalizations.of(context)?.errorMessage ??
              'Voice input unavailable',
        );
        return;
      }
      // Centralized permission + start
      final stream = await _voiceService.beginListening();
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _baseTextAtStart = _controller.text;
      });
      _textSub?.cancel();
      _textSub = stream.listen(
            (text) async {
          final updated = _baseTextAtStart.isEmpty
              ? text
              : '${_baseTextAtStart.trimRight()} $text';
          _controller.value = TextEditingValue(
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
      _ensureFocusedIfEnabled();
    } catch (_) {
      _showVoiceUnavailable(
        AppLocalizations.of(context)?.errorMessage ??
            'Failed to start voice input',
      );
      if (!mounted) return;
      setState(() => _isRecording = false);
    }
  }

  Future<void> _stopVoice() async {
    await _voiceService.stopListening();
    if (!mounted) return;
    setState(() => _isRecording = false);
    HapticFeedback.selectionClick();
  }

  // When on-device STT is unavailable we rely on server transcription.

  void _showVoiceUnavailable(String message) {
    if (!mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: AdaptiveSnackBarType.warning,
      duration: const Duration(seconds: 2),
    );
  }
}
