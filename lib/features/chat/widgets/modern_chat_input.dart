import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../../../shared/theme/theme_extensions.dart';
// app_theme not required here; using theme extension tokens
import '../../../shared/widgets/sheet_handle.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io' show Platform;
import 'dart:async';
import 'dart:ui';
import 'dart:math' as math;
import '../providers/chat_providers.dart';
import '../services/clipboard_attachment_service.dart';
import '../services/file_attachment_service.dart';
import '../providers/context_attachments_provider.dart';
import '../providers/knowledge_cache_provider.dart';
import '../../tools/providers/tools_providers.dart';
import '../../prompts/providers/prompts_providers.dart';
import '../../../core/models/tool.dart';
import '../../../core/models/prompt.dart';
import '../../../core/models/toggle_filter.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/settings_service.dart';
import '../../chat/services/voice_input_service.dart';
import '../../../core/models/knowledge_base.dart';

import '../../../shared/utils/platform_utils.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../core/utils/prompt_variable_parser.dart';
import '../../prompts/widgets/prompt_variable_dialog.dart';
import '../../auth/providers/unified_auth_providers.dart';

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

class _InsertNewlineIntent extends Intent {
  const _InsertNewlineIntent();
}

class _SelectNextPromptIntent extends Intent {
  const _SelectNextPromptIntent();
}

class _SelectPreviousPromptIntent extends Intent {
  const _SelectPreviousPromptIntent();
}

class _DismissPromptIntent extends Intent {
  const _DismissPromptIntent();
}

class _PromptCommandMatch {
  const _PromptCommandMatch({
    required this.command,
    required this.start,
    required this.end,
  });

  final String command;
  final int start;
  final int end;
}

class ModernChatInput extends ConsumerStatefulWidget {
  final Function(String) onSendMessage;
  final bool enabled;
  final Function()? onVoiceInput;
  final Function()? onVoiceCall;
  final Function()? onFileAttachment;
  final Function()? onImageAttachment;
  final Function()? onCameraCapture;
  final Function()? onWebAttachment;

  /// Callback invoked when images or files are pasted from clipboard.
  final Future<void> Function(List<LocalAttachment>)? onPastedAttachments;

  const ModernChatInput({
    super.key,
    required this.onSendMessage,
    this.enabled = true,
    this.onVoiceInput,
    this.onVoiceCall,
    this.onFileAttachment,
    this.onImageAttachment,
    this.onCameraCapture,
    this.onWebAttachment,
    this.onPastedAttachments,
  });

  @override
  ConsumerState<ModernChatInput> createState() => _ModernChatInputState();
}

// (Removed legacy _MicButton; inline mic logic now lives in primary button)

class _ModernChatInputState extends ConsumerState<ModernChatInput>
    with TickerProviderStateMixin {
  static const double _composerRadius = AppBorderRadius.card;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _pendingFocus = false;
  bool _isRecording = false;
  bool _hasText = false; // track locally without rebuilding on each keystroke
  StreamSubscription<String>? _voiceStreamSubscription;
  late VoiceInputService _voiceService;
  StreamSubscription<String>? _textSub;
  String _baseTextAtStart = '';
  bool _isDeactivated = false;
  int _lastHandledFocusTick = 0;
  bool _showPromptOverlay = false;
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

    // Publish focus changes to listeners
    _focusNode.addListener(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDeactivated) return;
        final hasFocus = _focusNode.hasFocus;
        // Publish composer focus state
        try {
          ref.read(composerHasFocusProvider.notifier).set(hasFocus);
        } catch (_) {}
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
    _textSub?.cancel();
    _voiceService.stopListening();
    super.dispose();
  }

  void _ensureFocusedIfEnabled() {
    // Respect global suppression flag to avoid re-opening keyboard
    final autofocusEnabled = ref.read(composerAutofocusEnabledProvider);
    if (!widget.enabled ||
        _focusNode.hasFocus ||
        _pendingFocus ||
        !autofocusEnabled) {
      return;
    }

    _pendingFocus = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingFocus = false;
      if (widget.enabled && !_focusNode.hasFocus) {
        _focusNode.requestFocus();
      }
    });
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

    PlatformUtils.lightHaptic();
    widget.onSendMessage(text);
    _controller.clear();

    // Dismiss keyboard after sending to recover screen space
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

  /// Builds a custom context menu with standard options plus "Paste Image".
  ///
  /// The standard paste only works for text. This adds a "Paste Image"
  /// option that uses the pasteboard package to read images from clipboard
  /// on both iOS and Android. The option only appears when there's actually
  /// an image in the clipboard.
  Widget _buildContextMenu(
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

    // Check clipboard for images - the data is captured in the closure to
    // avoid double-read and stale cache issues
    return FutureBuilder<Uint8List?>(
      future: _clipboardService.getClipboardImage(),
      builder: (context, snapshot) {
        final imageData = snapshot.data;
        final hasImage = imageData != null && imageData.isNotEmpty;

        if (hasImage) {
          // Find the index of the standard Paste button to insert after it
          final pasteIndex = buttonItems.indexWhere(
            (item) => item.type == ContextMenuButtonType.paste,
          );

          // Capture imageData in closure to avoid re-reading clipboard
          final pasteImageItem = ContextMenuButtonItem(
            label: AppLocalizations.of(context)?.pasteImage ?? 'Paste Image',
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

    final String text = _controller.text;
    final TextSelection selection = _controller.selection;
    final bool hasText = text.trim().isNotEmpty;
    final _PromptCommandMatch? match = _resolvePromptCommand(
      text,
      selection,
      widget.enabled,
    );
    final bool shouldShow = match != null;
    final bool wasShowing = _showPromptOverlay;
    final String previousCommand = _currentPromptCommand;

    bool needsUpdate = hasText != _hasText || shouldShow != _showPromptOverlay;

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
      // Trigger prompt fetch lazily when overlay first appears
      if (_currentPromptCommand.startsWith('/')) {
        ref.read(promptsListProvider.future);
      }
    }
  }

  _PromptCommandMatch? _resolvePromptCommand(
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
        !(candidate.startsWith('/') || candidate.startsWith('#'))) {
      return null;
    }

    return _PromptCommandMatch(command: candidate, start: start, end: cursor);
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

  void _movePromptSelection(int delta) {
    if (_currentPromptCommand.startsWith('#')) {
      // Only a single option in knowledge overlay; nothing to move.
      return;
    }

    final AsyncValue<List<Prompt>> promptsAsync = ref.read(promptsListProvider);
    final List<Prompt>? prompts = promptsAsync.value;
    if (prompts == null || prompts.isEmpty) return;

    final List<Prompt> filtered = _filterPrompts(prompts);
    if (filtered.isEmpty) return;

    int newIndex = _promptSelectionIndex + delta;
    if (newIndex < 0) {
      newIndex = 0;
    } else if (newIndex >= filtered.length) {
      newIndex = filtered.length - 1;
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
                      color: innerContext.conduitTheme.surfaceBackground,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(AppBorderRadius.modal),
                      ),
                      boxShadow: ConduitShadows.modal(innerContext),
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
                                return ListTile(
                                  dense: true,
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
                                      return ListTile(
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

  Widget _buildPromptOverlay(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    final overlayColor = context.conduitTheme.cardBackground;
    final borderColor = context.conduitTheme.cardBorder.withValues(
      alpha: brightness == Brightness.dark ? 0.6 : 0.4,
    );

    if (_currentPromptCommand.startsWith('#')) {
      return _buildKnowledgeOverlay(context, overlayColor, borderColor);
    }

    final AsyncValue<List<Prompt>> promptsAsync = ref.watch(
      promptsListProvider,
    );

    return Container(
      decoration: BoxDecoration(
        color: overlayColor,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: borderColor, width: BorderWidth.thin),
        boxShadow: [
          BoxShadow(
            color: context.conduitTheme.cardShadow.withValues(
              alpha: brightness == Brightness.dark ? 0.28 : 0.16,
            ),
            blurRadius: 22,
            offset: const Offset(0, 8),
            spreadRadius: -4,
          ),
        ],
      ),
      child: promptsAsync.when(
        data: (prompts) {
          final List<Prompt> filtered = _filterPrompts(prompts);
          if (filtered.isEmpty) {
            return _buildPromptOverlayPlaceholder(
              context,
              Icon(
                Icons.inbox_outlined,
                size: IconSize.medium,
                color: context.conduitTheme.textSecondary.withValues(
                  alpha: Alpha.medium,
                ),
              ),
              AppLocalizations.of(context)!.noResults,
            );
          }

          int activeIndex = _promptSelectionIndex;
          if (activeIndex < 0) {
            activeIndex = 0;
          } else if (activeIndex >= filtered.length) {
            activeIndex = filtered.length - 1;
          }

          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              itemCount: filtered.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(height: Spacing.xxs),
              itemBuilder: (context, index) {
                final prompt = filtered[index];
                final bool isSelected = index == activeIndex;
                final Color highlight = isSelected
                    ? context.conduitTheme.navigationSelectedBackground
                          .withValues(alpha: 0.4)
                    : Colors.transparent;

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppBorderRadius.card),
                    onTap: () => _applyPrompt(prompt),
                    child: Container(
                      decoration: BoxDecoration(
                        color: highlight,
                        borderRadius: BorderRadius.circular(
                          AppBorderRadius.card,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.xs,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            prompt.command,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: context.conduitTheme.textPrimary,
                                ),
                          ),
                          if (prompt.title.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: Spacing.xxs),
                              child: Text(
                                prompt.title,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: context.conduitTheme.textSecondary,
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
        loading: () => _buildPromptOverlayPlaceholder(
          context,
          SizedBox(
            width: IconSize.large,
            height: IconSize.large,
            child: CircularProgressIndicator(
              strokeWidth: BorderWidth.regular,
              valueColor: AlwaysStoppedAnimation<Color>(
                context.conduitTheme.loadingIndicator,
              ),
            ),
          ),
          null,
        ),
        error: (error, stackTrace) => _buildPromptOverlayPlaceholder(
          context,
          Icon(
            Icons.error_outline,
            size: IconSize.medium,
            color: context.conduitTheme.error,
          ),
          null,
        ),
      ),
    );
  }

  Widget _buildPromptOverlayPlaceholder(
    BuildContext context,
    Widget leading,
    String? message,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          leading,
          if (message != null) ...[
            const SizedBox(width: Spacing.sm),
            Flexible(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.conduitTheme.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
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
            color: context.conduitTheme.cardShadow.withValues(
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
      child: ListTile(
        title: const Text('Browse knowledge base'),
        subtitle: const Text('Press Enter to pick a document'),
        leading: const Icon(Icons.folder_outlined),
        onTap: _openKnowledgePicker,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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

    final messages = ref.watch(chatMessagesProvider);
    final isGenerating =
        messages.isNotEmpty &&
        messages.last.role == 'assistant' &&
        messages.last.isStreaming;
    final stopGeneration = ref.read(stopGenerationProvider);

    final webSearchEnabled = ref.watch(webSearchEnabledProvider);
    final imageGenEnabled = ref.watch(imageGenerationEnabledProvider);
    final imageGenAvailable = ref.watch(imageGenerationAvailableProvider);
    final extendedThinkingEnabled = ref.watch(extendedThinkingEnabledProvider);
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
    final bool isActive = _focusNode.hasFocus || _hasText;
    final Color composerSurface = context.conduitTheme.inputBackground;
    final Color composerBackground = brightness == Brightness.dark
        ? composerSurface.withValues(alpha: 0.78)
        : context.conduitTheme.surfaceContainerHighest;
    final Color placeholderBase = context.conduitTheme.inputText.withValues(
      alpha: 0.64,
    );
    final Color placeholderFocused = context.conduitTheme.inputText.withValues(
      alpha: 0.64,
    );
    final Color outlineColor = Color.lerp(
      context.conduitTheme.inputBorder,
      context.conduitTheme.inputBorderFocused,
      isActive ? 1.0 : 0.0,
    )!.withValues(alpha: brightness == Brightness.dark ? 0.55 : 0.45);
    final Color shellShadowColor = context.conduitTheme.cardShadow.withValues(
      alpha: brightness == Brightness.dark
          ? 0.22 + (isActive ? 0.08 : 0.0)
          : 0.12 + (isActive ? 0.06 : 0.0),
    );

    final List<Widget> quickPills = <Widget>[];

    for (final id in selectedQuickPills) {
      if (id == 'web' && showWebPill) {
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
              onTap: widget.enabled && !_isRecording ? handleTap : null,
            ),
          );
        }
      }
    }

    final bool showCompactComposer = quickPills.isEmpty;

    final BorderRadius shellRadius = BorderRadius.circular(
      showCompactComposer ? AppBorderRadius.round : _composerRadius,
    );

    final BoxDecoration shellDecoration = BoxDecoration(
      color: showCompactComposer ? Colors.transparent : composerBackground,
      borderRadius: shellRadius,
      border: showCompactComposer
          ? null
          : Border.all(color: outlineColor, width: BorderWidth.thin),
      boxShadow: showCompactComposer
          ? const <BoxShadow>[]
          : <BoxShadow>[
              BoxShadow(
                color: shellShadowColor,
                blurRadius: 12 + (isActive ? 4 : 0),
                spreadRadius: -2,
                offset: const Offset(0, -2),
              ),
            ],
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
          child: _buildPromptOverlay(context),
        ),
      if (showCompactComposer)
        Padding(
          key: const ValueKey('composer-compact'),
          padding: const EdgeInsets.fromLTRB(
            Spacing.screenPadding,
            Spacing.xs,
            Spacing.screenPadding,
            Spacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _buildOverflowButton(
                tooltip: AppLocalizations.of(context)!.more,
                webSearchActive: webSearchEnabled,
                imageGenerationActive: imageGenEnabled,
                extendedThinkingActive: extendedThinkingEnabled,
                toolsActive: selectedToolIds.isNotEmpty,
                filtersActive: selectedFilterIds.isNotEmpty,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.25,
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                    constraints: const BoxConstraints(
                      minHeight: TouchTarget.input,
                    ),
                    decoration: BoxDecoration(
                      color: composerSurface.withValues(
                        alpha: brightness == Brightness.dark ? 0.9 : 0.2,
                      ),
                      borderRadius: BorderRadius.circular(_composerRadius),
                      border: Border.all(
                        color: outlineColor.withValues(
                          alpha: brightness == Brightness.dark ? 0.32 : 0.2,
                        ),
                        width: BorderWidth.micro,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _buildComposerTextField(
                            brightness: brightness,
                            sendOnEnter: sendOnEnter,
                            placeholderBase: placeholderBase,
                            placeholderFocused: placeholderFocused,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: Spacing.xs,
                            ),
                            isActive: isActive,
                          ),
                        ),
                        if (!_hasText && voiceAvailable && !isGenerating)
                          _buildInlineMicIcon(voiceAvailable),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              _buildPrimaryButton(
                _hasText,
                isGenerating,
                stopGeneration,
                voiceAvailable,
              ),
            ],
          ),
        )
      else ...[
        Padding(
          key: const ValueKey('composer-expanded-input'),
          padding: const EdgeInsets.fromLTRB(
            Spacing.sm,
            Spacing.xs,
            Spacing.sm,
            Spacing.xs,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(
              Spacing.sm,
              Spacing.xs,
              Spacing.sm,
              Spacing.xs,
            ),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(_composerRadius),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _buildComposerTextField(
                    brightness: brightness,
                    sendOnEnter: sendOnEnter,
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
          ),
        ),
        Padding(
          key: const ValueKey('composer-expanded-buttons'),
          padding: const EdgeInsets.fromLTRB(
            Spacing.inputPadding,
            0,
            Spacing.inputPadding,
            0,
          ),
          child: Row(
            children: [
              _buildOverflowButton(
                tooltip: AppLocalizations.of(context)!.more,
                webSearchActive: webSearchEnabled,
                imageGenerationActive: imageGenEnabled,
                extendedThinkingActive: extendedThinkingEnabled,
                toolsActive: selectedToolIds.isNotEmpty,
                filtersActive: selectedFilterIds.isNotEmpty,
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
              const SizedBox(width: Spacing.sm),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_hasText && voiceAvailable && !isGenerating) ...[
                    _buildMicButton(voiceAvailable),
                    const SizedBox(width: Spacing.sm),
                  ],
                  _buildPrimaryButton(
                    _hasText,
                    isGenerating,
                    stopGeneration,
                    voiceAvailable,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ];

    Widget shell = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      decoration: shellDecoration,
      width: double.infinity,
      child: SafeArea(
        top: false,
        bottom: true,
        child: ConstrainedBox(
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
        ),
      ),
    );

    if (brightness == Brightness.dark && !showCompactComposer) {
      shell = ClipRRect(
        borderRadius: shellRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: shell,
        ),
      );
    }

    return Container(
      color: Colors.transparent,
      padding: EdgeInsets.zero,
      child: Column(mainAxisSize: MainAxisSize.min, children: [shell]),
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
    required Color placeholderBase,
    required Color placeholderFocused,
    required EdgeInsetsGeometry contentPadding,
    required bool isActive,
  }) {
    return GestureDetector(
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
                const _SendMessageIntent(),
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.enter):
                const _SendMessageIntent(),
          };
          if (sendOnEnter) {
            map[LogicalKeySet(LogicalKeyboardKey.enter)] =
                const _SendMessageIntent();
            map[LogicalKeySet(
                  LogicalKeyboardKey.shift,
                  LogicalKeyboardKey.enter,
                )] =
                const _InsertNewlineIntent();
          }
          if (_showPromptOverlay) {
            map[LogicalKeySet(LogicalKeyboardKey.arrowDown)] =
                const _SelectNextPromptIntent();
            map[LogicalKeySet(LogicalKeyboardKey.arrowUp)] =
                const _SelectPreviousPromptIntent();
            map[LogicalKeySet(LogicalKeyboardKey.escape)] =
                const _DismissPromptIntent();
          }
          return map;
        }(),
        child: Actions(
          actions: <Type, Action<Intent>>{
            _SendMessageIntent: CallbackAction<_SendMessageIntent>(
              onInvoke: (intent) {
                if (_showPromptOverlay) {
                  _confirmPromptSelection();
                  return null;
                }
                _sendMessage();
                return null;
              },
            ),
            _InsertNewlineIntent: CallbackAction<_InsertNewlineIntent>(
              onInvoke: (intent) {
                _insertNewline();
                return null;
              },
            ),
            _SelectNextPromptIntent: CallbackAction<_SelectNextPromptIntent>(
              onInvoke: (intent) {
                _movePromptSelection(1);
                return null;
              },
            ),
            _SelectPreviousPromptIntent:
                CallbackAction<_SelectPreviousPromptIntent>(
                  onInvoke: (intent) {
                    _movePromptSelection(-1);
                    return null;
                  },
                ),
            _DismissPromptIntent: CallbackAction<_DismissPromptIntent>(
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
              final Color animatedTextColor = Color.lerp(
                context.conduitTheme.inputText.withValues(alpha: 0.88),
                context.conduitTheme.inputText,
                factor,
              )!;

              final FontWeight recordingWeight = _isRecording
                  ? FontWeight.w500
                  : FontWeight.w400;
              final TextStyle baseChatStyle = AppTypography.chatMessageStyle;

              // Wrap with Semantics to provide an accessible label for screen
              // readers. We avoid MergeSemantics which caused double-
              // announcements. The TextField provides its own text field
              // semantics; this just adds the descriptive label.
              return Semantics(
                label: AppLocalizations.of(context)!.messageInputLabel,
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  enabled: widget.enabled,
                  autofocus: false,
                  minLines: 1,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: sendOnEnter
                      ? TextInputAction.send
                      : TextInputAction.newline,
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
                  decoration: InputDecoration(
                    hintText: AppLocalizations.of(context)!.messageHintText,
                    hintStyle: baseChatStyle.copyWith(
                      color: animatedPlaceholder,
                      fontWeight: recordingWeight,
                      fontStyle: _isRecording
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
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
                  // Custom context menu with "Paste Image" option for iOS
                  contextMenuBuilder: (context, editableTextState) {
                    return _buildContextMenu(context, editableTextState);
                  },
                  onSubmitted: (_) {
                    if (sendOnEnter) {
                      _sendMessage();
                    }
                  },
                  onTap: () {
                    if (!widget.enabled) return;
                    _ensureFocusedIfEnabled();
                  },
                ),
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
    required bool extendedThinkingActive,
    required bool toolsActive,
    required bool filtersActive,
  }) {
    final bool enabled = widget.enabled && !_isRecording;

    IconData icon;
    Color? activeColor;
    if (webSearchActive) {
      icon = Platform.isIOS ? CupertinoIcons.search : Icons.search;
      activeColor = context.conduitTheme.buttonPrimary;
    } else if (imageGenerationActive) {
      icon = Platform.isIOS ? CupertinoIcons.photo : Icons.image;
      activeColor = context.conduitTheme.buttonPrimary;
    } else if (extendedThinkingActive) {
      icon = Icons.psychology;
      activeColor = context.conduitTheme.buttonPrimary;
    } else if (toolsActive) {
      icon = Platform.isIOS ? CupertinoIcons.wrench : Icons.build;
      activeColor = context.conduitTheme.buttonPrimary;
    } else if (filtersActive) {
      icon = Platform.isIOS ? CupertinoIcons.sparkles : Icons.auto_awesome;
      activeColor = context.conduitTheme.buttonPrimary;
    } else {
      icon = Platform.isIOS ? CupertinoIcons.add : Icons.add;
      activeColor = null;
    }

    const double iconSize = IconSize.large;
    const double buttonSize = TouchTarget.minimum;
    final bool isActive = activeColor != null;

    final Color iconColor = !enabled
        ? context.conduitTheme.textPrimary.withValues(alpha: Alpha.disabled)
        : (activeColor ??
              context.conduitTheme.textPrimary.withValues(alpha: Alpha.strong));

    final Brightness brightness = Theme.of(context).brightness;
    final Color baseBackground = context.conduitTheme.inputBackground
        .withValues(alpha: brightness == Brightness.dark ? 0.9 : 0.2);
    final Color backgroundColor = !enabled
        ? baseBackground.withValues(alpha: Alpha.disabled)
        : isActive
        ? context.conduitTheme.buttonPrimary.withValues(alpha: 0.16)
        : baseBackground;
    final Color borderColor = isActive
        ? context.conduitTheme.buttonPrimary.withValues(alpha: 0.6)
        : context.conduitTheme.cardBorder.withValues(alpha: 0.45);

    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: enabled ? 1.0 : Alpha.disabled,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppBorderRadius.round),
            onTap: enabled
                ? () {
                    HapticFeedback.selectionClick();
                    _showOverflowSheet();
                  }
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: buttonSize,
              height: buttonSize,
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(AppBorderRadius.round),
                border: Border.all(color: borderColor, width: BorderWidth.thin),
              ),
              child: Center(
                child: Icon(icon, size: iconSize, color: iconColor),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMicButton(bool voiceAvailable) {
    final bool enabledMic = widget.enabled && voiceAvailable;
    return Tooltip(
      message: AppLocalizations.of(context)!.voiceInput,
      child: Opacity(
        opacity: enabledMic ? Alpha.primary : Alpha.disabled,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppBorderRadius.circular),
            onTap: enabledMic
                ? () {
                    HapticFeedback.selectionClick();
                    _toggleVoice();
                  }
                : null,
            child: SizedBox(
              width: TouchTarget.minimum,
              height: TouchTarget.minimum,
              child: Icon(
                Platform.isIOS ? CupertinoIcons.mic : Icons.mic,
                size: IconSize.large,
                color: _isRecording
                    ? context.conduitTheme.buttonPrimary
                    : (enabledMic
                          ? context.conduitTheme.textPrimary.withValues(
                              alpha: Alpha.strong,
                            )
                          : context.conduitTheme.textPrimary.withValues(
                              alpha: Alpha.disabled,
                            )),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInlineMicIcon(bool voiceAvailable) {
    final bool enabledMic = widget.enabled && voiceAvailable;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppBorderRadius.circular),
        onTap: enabledMic
            ? () {
                HapticFeedback.selectionClick();
                _toggleVoice();
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xs),
          child: Icon(
            Platform.isIOS ? CupertinoIcons.mic : Icons.mic,
            size: IconSize.medium,
            color: _isRecording
                ? context.conduitTheme.buttonPrimary
                : context.conduitTheme.textSecondary.withValues(
                    alpha: enabledMic ? Alpha.strong : Alpha.disabled,
                  ),
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
  ) {
    // Compact 44px touch target, circular radius, md icon size
    const double buttonSize = TouchTarget.minimum; // 44.0
    const double radius = AppBorderRadius.round; // big to ensure circle

    final enabled = !isGenerating && hasText && widget.enabled;

    // Generating -> STOP variant
    if (isGenerating) {
      return Tooltip(
        message: AppLocalizations.of(context)!.stopGenerating,
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(
              color: context.conduitTheme.error,
              width: BorderWidth.regular,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(radius),
            overlayColor: WidgetStateProperty.resolveWith<Color>((
              Set<WidgetState> states,
            ) {
              if (states.contains(WidgetState.pressed)) {
                return context.conduitTheme.error.withValues(
                  alpha: Alpha.buttonPressed,
                );
              }
              if (states.contains(WidgetState.hovered)) {
                return context.conduitTheme.error.withValues(
                  alpha: Alpha.hover,
                );
              }
              return Colors.transparent;
            }),
            onTap: () {
              HapticFeedback.lightImpact();
              stopGeneration();
            },
            child: Container(
              width: buttonSize,
              height: buttonSize,
              decoration: BoxDecoration(
                color: context.conduitTheme.error.withValues(
                  alpha: Alpha.buttonPressed,
                ),
                borderRadius: BorderRadius.circular(radius),
                boxShadow: ConduitShadows.button(context),
              ),
              child: Center(
                child: Icon(
                  Platform.isIOS ? CupertinoIcons.stop_fill : Icons.stop,
                  size: IconSize.large,
                  color: context.conduitTheme.buttonPrimaryText,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // If there's text, render SEND variant; otherwise render VOICE CALL variant
    if (hasText) {
      return Tooltip(
        message: enabled
            ? AppLocalizations.of(context)!.sendMessage
            : AppLocalizations.of(context)!.send,
        child: Opacity(
          opacity: enabled ? Alpha.primary : Alpha.disabled,
          child: IgnorePointer(
            ignoring: !enabled,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(radius),
                onTap: enabled
                    ? () {
                        PlatformUtils.lightHaptic();
                        _sendMessage();
                      }
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  width: buttonSize,
                  height: buttonSize,
                  decoration: BoxDecoration(
                    color: enabled
                        ? context.conduitTheme.buttonPrimary
                        : context.conduitTheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(
                      color: enabled
                          ? context.conduitTheme.buttonPrimary.withValues(
                              alpha: 0.8,
                            )
                          : context.conduitTheme.cardBorder.withValues(
                              alpha: 0.45,
                            ),
                      width: BorderWidth.thin,
                    ),
                    boxShadow: enabled
                        ? <BoxShadow>[
                            BoxShadow(
                              color: context.conduitTheme.cardShadow.withValues(
                                alpha:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? 0.36
                                    : 0.18,
                              ),
                              blurRadius: 18,
                              spreadRadius: -6,
                              offset: const Offset(0, 8),
                            ),
                          ]
                        : const [],
                  ),
                  child: Center(
                    child: Icon(
                      Platform.isIOS
                          ? CupertinoIcons.arrow_up
                          : Icons.arrow_upward,
                      size: IconSize.large,
                      color: enabled
                          ? context.conduitTheme.buttonPrimaryText
                          : context.conduitTheme.textPrimary.withValues(
                              alpha: Alpha.disabled,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // VOICE CALL variant when no text is present
    final bool enabledVoiceCall = widget.enabled && widget.onVoiceCall != null;
    return Tooltip(
      message: 'Voice Call',
      child: Opacity(
        opacity: enabledVoiceCall ? Alpha.primary : Alpha.disabled,
        child: IgnorePointer(
          ignoring: !enabledVoiceCall,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(radius),
              onTap: enabledVoiceCall
                  ? () {
                      PlatformUtils.lightHaptic();
                      widget.onVoiceCall!();
                    }
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                width: buttonSize,
                height: buttonSize,
                decoration: BoxDecoration(
                  color: enabledVoiceCall
                      ? context.conduitTheme.buttonPrimary
                      : context.conduitTheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: enabledVoiceCall
                        ? context.conduitTheme.buttonPrimary.withValues(
                            alpha: 0.8,
                          )
                        : context.conduitTheme.cardBorder.withValues(
                            alpha: 0.45,
                          ),
                    width: BorderWidth.thin,
                  ),
                  boxShadow: enabledVoiceCall
                      ? <BoxShadow>[
                          BoxShadow(
                            color: context.conduitTheme.cardShadow.withValues(
                              alpha:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? 0.36
                                  : 0.18,
                            ),
                            blurRadius: 18,
                            spreadRadius: -6,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : const [],
                ),
                child: Center(
                  child: Icon(
                    Platform.isIOS ? CupertinoIcons.waveform : Icons.graphic_eq,
                    size: IconSize.large,
                    color: enabledVoiceCall
                        ? context.conduitTheme.buttonPrimaryText
                        : context.conduitTheme.textPrimary.withValues(
                            alpha: Alpha.disabled,
                          ),
                  ),
                ),
              ),
            ),
          ),
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
  }) {
    final bool enabled = onTap != null;
    final Brightness brightness = Theme.of(context).brightness;
    final theme = context.conduitTheme;

    // Enhanced color scheme for active state
    final Color activeBackground = isActive
        ? theme.buttonPrimary.withValues(
            alpha: brightness == Brightness.dark ? 0.22 : 0.14,
          )
        : Colors.transparent;

    final Color inactiveBackground = brightness == Brightness.dark
        ? theme.cardBackground.withValues(alpha: 0.25)
        : theme.cardBackground.withValues(alpha: 0.08);

    final Color background = isActive ? activeBackground : inactiveBackground;

    // Enhanced border styling
    final Color activeBorder = theme.buttonPrimary.withValues(
      alpha: brightness == Brightness.dark ? 0.85 : 0.75,
    );
    final Color inactiveBorder = theme.cardBorder.withValues(
      alpha: brightness == Brightness.dark ? 0.4 : 0.25,
    );
    final Color borderColor = isActive ? activeBorder : inactiveBorder;

    // Enhanced content colors
    final Color activeTextColor = theme.buttonPrimary;
    final Color inactiveTextColor = theme.textPrimary.withValues(
      alpha: enabled
          ? (brightness == Brightness.dark ? 0.85 : 0.75)
          : Alpha.disabled,
    );
    final Color textColor = isActive ? activeTextColor : inactiveTextColor;

    final Color iconColor = isActive ? activeTextColor : inactiveTextColor;

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
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm - 2,
            ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppBorderRadius.round),
              border: Border.all(
                color: borderColor,
                width: isActive ? BorderWidth.medium : BorderWidth.thin,
              ),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: theme.buttonPrimary.withValues(
                          alpha: brightness == Brightness.dark ? 0.25 : 0.15,
                        ),
                        blurRadius: 8,
                        spreadRadius: 0,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : [],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  child: iconUrl != null && iconUrl.isNotEmpty
                      ? SizedBox(
                          width: IconSize.small + 1,
                          height: IconSize.small + 1,
                          child: Image.network(
                            iconUrl,
                            width: IconSize.small + 1,
                            height: IconSize.small + 1,
                            color: iconUrl.endsWith('.svg') ? iconColor : null,
                            colorBlendMode: BlendMode.srcIn,
                            errorBuilder: (_, _, _) => Icon(
                              icon,
                              size: IconSize.small + 1,
                              color: iconColor,
                            ),
                          ),
                        )
                      : Icon(icon, size: IconSize.small + 1, color: iconColor),
                ),
                const SizedBox(width: Spacing.xs + 1),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  style: AppTypography.labelStyle.copyWith(
                    color: textColor,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    fontSize: 13,
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
      builder: (modalContext) => Consumer(
        builder: (innerContext, modalRef, _) {
          final l10n = AppLocalizations.of(innerContext)!;
          final theme = innerContext.conduitTheme;

          final attachments = <Widget>[
            _buildOverflowAction(
              icon: Platform.isIOS ? CupertinoIcons.doc : Icons.attach_file,
              label: l10n.file,
              onTap: widget.onFileAttachment == null
                  ? null
                  : () {
                      HapticFeedback.lightImpact();
                      widget.onFileAttachment!.call();
                    },
            ),
            _buildOverflowAction(
              icon: Platform.isIOS ? CupertinoIcons.photo : Icons.image,
              label: l10n.photo,
              onTap: widget.onImageAttachment == null
                  ? null
                  : () {
                      HapticFeedback.lightImpact();
                      widget.onImageAttachment!.call();
                    },
            ),
            _buildOverflowAction(
              icon: Platform.isIOS ? CupertinoIcons.camera : Icons.camera_alt,
              label: l10n.camera,
              onTap: widget.onCameraCapture == null
                  ? null
                  : () {
                      HapticFeedback.lightImpact();
                      widget.onCameraCapture!.call();
                    },
            ),
            _buildOverflowAction(
              icon: Icons.public,
              label: 'Attach webpage',
              onTap: widget.onWebAttachment == null
                  ? null
                  : () {
                      HapticFeedback.lightImpact();
                      widget.onWebAttachment!.call();
                    },
            ),
          ];

          final featureTiles = <Widget>[];
          final webSearchAvailable = modalRef.watch(webSearchAvailableProvider);
          final webSearchEnabled = modalRef.watch(webSearchEnabledProvider);
          if (webSearchAvailable) {
            featureTiles.add(
              _buildFeatureToggleTile(
                icon: Platform.isIOS ? CupertinoIcons.search : Icons.search,
                title: l10n.webSearch,
                subtitle: l10n.webSearchDescription,
                value: webSearchEnabled,
                onChanged: (next) {
                  modalRef.read(webSearchEnabledProvider.notifier).set(next);
                },
              ),
            );
          }

          final extendedThinkingEnabled = modalRef.watch(extendedThinkingEnabledProvider);
          featureTiles.add(
            _buildFeatureToggleTile(
              icon: Icons.psychology,
              title: l10n.extendedThinking,
              subtitle: l10n.extendedThinkingDescription,
              value: extendedThinkingEnabled,
              onChanged: (next) {
                modalRef.read(extendedThinkingEnabledProvider.notifier).set(next);
              },
            ),
          );

          final imageGenAvailable = modalRef.watch(
            imageGenerationAvailableProvider,
          );
          final imageGenEnabled = modalRef.watch(
            imageGenerationEnabledProvider,
          );
          if (imageGenAvailable) {
            featureTiles.add(
              _buildFeatureToggleTile(
                icon: Platform.isIOS ? CupertinoIcons.photo : Icons.image,
                title: l10n.imageGeneration,
                subtitle: l10n.imageGenerationDescription,
                value: imageGenEnabled,
                onChanged: (next) {
                  modalRef
                      .read(imageGenerationEnabledProvider.notifier)
                      .set(next);
                },
              ),
            );
          }

          final selectedToolIds = modalRef.watch(selectedToolIdsProvider);
          final toolsAsync = modalRef.watch(toolsListProvider);
          final Widget toolsSection = toolsAsync.when(
            data: (tools) {
              if (tools.isEmpty) {
                return _buildInfoCard('No tools available');
              }
              final tiles = tools.map((tool) {
                final isSelected = selectedToolIds.contains(tool.id);
                return _buildToolTile(
                  tool: tool,
                  selected: isSelected,
                  onToggle: () {
                    final current = List<String>.from(
                      modalRef.read(selectedToolIdsProvider),
                    );
                    if (isSelected) {
                      current.remove(tool.id);
                    } else {
                      current.add(tool.id);
                    }
                    modalRef
                        .read(selectedToolIdsProvider.notifier)
                        .set(current);
                  },
                );
              }).toList();
              return Column(children: _withVerticalSpacing(tiles, Spacing.xxs));
            },
            loading: () => Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: BorderWidth.thin),
              ),
            ),
            error: (error, stack) => _buildInfoCard('Failed to load tools'),
          );

          final bodyChildren = <Widget>[
            const SheetHandle(),
            const SizedBox(height: Spacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < attachments.length; i++) ...[
                      if (i != 0) const SizedBox(width: Spacing.sm),
                      Expanded(child: attachments[i]),
                    ],
                  ],
                ),
              ],
            ),
          ];

          if (featureTiles.isNotEmpty) {
            bodyChildren
              ..add(const SizedBox(height: Spacing.sm))
              ..addAll(_withVerticalSpacing(featureTiles, Spacing.xxs));
          }

          bodyChildren
            ..add(const SizedBox(height: Spacing.sm))
            ..add(_buildSectionLabel(l10n.tools))
            ..add(toolsSection);

          // Add filters section (like tools section)
          final modalSelectedModel = modalRef.watch(selectedModelProvider);
          final modalToggleFilters =
              modalSelectedModel?.filters ?? const <ToggleFilter>[];

          if (modalToggleFilters.isNotEmpty) {
            final modalSelectedFilterIds = modalRef.watch(
              selectedFilterIdsProvider,
            );
            final filterTiles = modalToggleFilters.map((filter) {
              final isSelected = modalSelectedFilterIds.contains(filter.id);
              return _buildFilterTile(
                filter: filter,
                selected: isSelected,
                onToggle: () {
                  modalRef
                      .read(selectedFilterIdsProvider.notifier)
                      .toggle(filter.id);
                },
              );
            }).toList();

            bodyChildren
              ..add(const SizedBox(height: Spacing.sm))
              ..add(_buildSectionLabel(l10n.filters))
              ..add(
                Column(
                  children: _withVerticalSpacing(filterTiles, Spacing.xxs),
                ),
              );
          }

          // Measure content height and cap the sheet's max size to avoid extra blank space
          final GlobalKey sheetContentKey = GlobalKey();
          double? measuredContentHeight;

          return StatefulBuilder(
            builder: (context, setModalState) {
              // Schedule a post-frame measurement of the content height
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final ctx = sheetContentKey.currentContext;
                if (ctx != null) {
                  final renderObject = ctx.findRenderObject();
                  if (renderObject is RenderBox) {
                    final double h = renderObject.size.height;
                    if (h > 0 && h != measuredContentHeight) {
                      measuredContentHeight = h;
                      setModalState(() {});
                    }
                  }
                }
              });

              final media = MediaQuery.of(modalContext);
              final double availableHeight =
                  media.size.height - media.padding.top;

              double computedMax = 0.9;
              if (measuredContentHeight != null && availableHeight > 0) {
                computedMax = (measuredContentHeight! / availableHeight).clamp(
                  0.1,
                  0.9,
                );
              }
              final double computedMin = math.min(0.2, computedMax);
              final double computedInitial = math.min(0.34, computedMax);

              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(modalContext).maybePop(),
                      child: const SizedBox.shrink(),
                    ),
                  ),
                  DraggableScrollableSheet(
                    expand: false,
                    initialChildSize: computedInitial,
                    minChildSize: computedMin,
                    maxChildSize: computedMax,
                    snap: true,
                    snapSizes: [computedMax],
                    builder: (sheetContext, scrollController) {
                      return Container(
                        decoration: BoxDecoration(
                          color: theme.surfaceBackground,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(AppBorderRadius.bottomSheet),
                          ),
                          border: Border.all(
                            color: theme.dividerColor,
                            width: BorderWidth.thin,
                          ),
                          boxShadow: ConduitShadows.modal(context),
                        ),
                        child: ModalSheetSafeArea(
                          padding: const EdgeInsets.fromLTRB(
                            Spacing.md,
                            Spacing.xs,
                            Spacing.md,
                            Spacing.md,
                          ),
                          child: SingleChildScrollView(
                            controller: scrollController,
                            padding: EdgeInsets.zero,
                            child: Column(
                              key: sheetContentKey,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: bodyChildren,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          );
        },
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

  List<Widget> _withVerticalSpacing(List<Widget> children, double gap) {
    if (children.length <= 1) {
      return List<Widget>.from(children);
    }
    final spaced = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      spaced.add(children[i]);
      if (i != children.length - 1) {
        spaced.add(SizedBox(height: gap));
      }
    }
    return spaced;
  }

  Widget _buildSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xxs),
      child: Text(
        text,
        style: AppTypography.labelStyle.copyWith(
          color: context.conduitTheme.textSecondary.withValues(
            alpha: Alpha.strong,
          ),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildFeatureToggleTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? iconUrl,
  }) {
    final theme = context.conduitTheme;
    final brightness = Theme.of(context).brightness;
    final description = subtitle?.trim() ?? '';

    final Color background = value
        ? theme.buttonPrimary.withValues(
            alpha: brightness == Brightness.dark ? 0.28 : 0.16,
          )
        : theme.surfaceContainer.withValues(
            alpha: brightness == Brightness.dark ? 0.32 : 0.12,
          );
    final Color borderColor = value
        ? theme.buttonPrimary.withValues(alpha: 0.7)
        : theme.cardBorder.withValues(alpha: 0.55);

    return Semantics(
      button: true,
      toggled: value,
      label: title,
      hint: description.isEmpty ? null : description,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppBorderRadius.input),
          onTap: () {
            HapticFeedback.selectionClick();
            onChanged(!value);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(vertical: Spacing.xxs),
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppBorderRadius.input),
              border: Border.all(color: borderColor, width: BorderWidth.thin),
              boxShadow: value ? ConduitShadows.low(context) : const [],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                iconUrl != null && iconUrl.isNotEmpty
                    ? _buildFilterGlyph(
                        iconUrl: iconUrl,
                        selected: value,
                        theme: theme,
                      )
                    : _buildToolGlyph(
                        icon: icon,
                        selected: value,
                        theme: theme,
                      ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: value ? FontWeight.w600 : FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: Spacing.xs),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.captionStyle.copyWith(
                            color: theme.textSecondary.withValues(
                              alpha: Alpha.strong,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                _buildTogglePill(isOn: value, theme: theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolTile({
    required Tool tool,
    required bool selected,
    required VoidCallback onToggle,
  }) {
    final theme = context.conduitTheme;
    final brightness = Theme.of(context).brightness;
    final description = _toolDescriptionFor(tool);
    final Color background = selected
        ? theme.buttonPrimary.withValues(
            alpha: brightness == Brightness.dark ? 0.28 : 0.16,
          )
        : theme.surfaceContainer.withValues(
            alpha: brightness == Brightness.dark ? 0.32 : 0.12,
          );
    final Color borderColor = selected
        ? theme.buttonPrimary.withValues(alpha: 0.7)
        : theme.cardBorder.withValues(alpha: 0.55);

    return Semantics(
      button: true,
      toggled: selected,
      label: tool.name,
      hint: description.isEmpty ? null : description,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppBorderRadius.input),
          onTap: () {
            HapticFeedback.selectionClick();
            onToggle();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(vertical: Spacing.xxs),
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppBorderRadius.input),
              border: Border.all(color: borderColor, width: BorderWidth.thin),
              boxShadow: selected ? ConduitShadows.low(context) : const [],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildToolGlyph(
                  icon: _toolIconFor(tool),
                  selected: selected,
                  theme: theme,
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tool.name,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: Spacing.xs),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.captionStyle.copyWith(
                            color: theme.textSecondary.withValues(
                              alpha: Alpha.strong,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                _buildTogglePill(isOn: selected, theme: theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterTile({
    required ToggleFilter filter,
    required bool selected,
    required VoidCallback onToggle,
  }) {
    final theme = context.conduitTheme;
    final brightness = Theme.of(context).brightness;
    final description = filter.description ?? '';
    final Color background = selected
        ? theme.buttonPrimary.withValues(
            alpha: brightness == Brightness.dark ? 0.28 : 0.16,
          )
        : theme.surfaceContainer.withValues(
            alpha: brightness == Brightness.dark ? 0.32 : 0.12,
          );
    final Color borderColor = selected
        ? theme.buttonPrimary.withValues(alpha: 0.7)
        : theme.cardBorder.withValues(alpha: 0.55);

    return Semantics(
      button: true,
      toggled: selected,
      label: filter.name,
      hint: description.isEmpty ? null : description,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppBorderRadius.input),
          onTap: () {
            HapticFeedback.selectionClick();
            onToggle();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(vertical: Spacing.xxs),
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppBorderRadius.input),
              border: Border.all(color: borderColor, width: BorderWidth.thin),
              boxShadow: selected ? ConduitShadows.low(context) : const [],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildFilterGlyph(
                  iconUrl: filter.icon,
                  selected: selected,
                  theme: theme,
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        filter.name,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: Spacing.xs),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.captionStyle.copyWith(
                            color: theme.textSecondary.withValues(
                              alpha: Alpha.strong,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                _buildTogglePill(isOn: selected, theme: theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolGlyph({
    required IconData icon,
    required bool selected,
    required ConduitThemeExtension theme,
  }) {
    final Color accentStart = theme.buttonPrimary.withValues(
      alpha: selected ? Alpha.active : Alpha.hover,
    );
    final Color accentEnd = theme.buttonPrimary.withValues(
      alpha: selected ? Alpha.highlight : Alpha.focus,
    );
    final Color iconColor = selected
        ? theme.buttonPrimaryText
        : theme.iconPrimary.withValues(alpha: Alpha.strong);

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accentStart, accentEnd],
        ),
      ),
      child: Icon(icon, color: iconColor, size: IconSize.modal),
    );
  }

  String _toolDescriptionFor(Tool tool) {
    final metaDescription = _extractMetaDescription(tool.meta);
    if (metaDescription != null && metaDescription.isNotEmpty) {
      return metaDescription;
    }

    final custom = tool.description?.trim();
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }

    final name = tool.name.toLowerCase();
    if (name.contains('search') || name.contains('browse')) {
      return 'Search the web for fresh context to improve answers.';
    }
    if (name.contains('image') ||
        name.contains('vision') ||
        name.contains('media')) {
      return 'Understand or generate imagery alongside your conversation.';
    }
    if (name.contains('code') ||
        name.contains('python') ||
        name.contains('notebook')) {
      return 'Execute code snippets and return computed results inline.';
    }
    if (name.contains('calc') || name.contains('math')) {
      return 'Perform precise math and calculations on demand.';
    }
    if (name.contains('file') || name.contains('document')) {
      return 'Access and summarize your uploaded files during chat.';
    }
    if (name.contains('api') || name.contains('request')) {
      return 'Trigger API requests and bring external data into the chat.';
    }
    return 'Enhance responses with specialized capabilities from this tool.';
  }

  String? _extractMetaDescription(Map<String, dynamic>? meta) {
    if (meta == null || meta.isEmpty) return null;
    final value = meta['description'];
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// Builds the circular glyph/avatar for a filter tile.
  Widget _buildFilterGlyph({
    String? iconUrl,
    required bool selected,
    required ConduitThemeExtension theme,
  }) {
    final Color accentStart = theme.buttonPrimary.withValues(
      alpha: selected ? Alpha.active : Alpha.hover,
    );
    final Color accentEnd = theme.buttonPrimary.withValues(
      alpha: selected ? Alpha.highlight : Alpha.focus,
    );
    final Color iconColor = selected
        ? theme.buttonPrimaryText
        : theme.iconPrimary.withValues(alpha: Alpha.strong);

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accentStart, accentEnd],
        ),
      ),
      child: iconUrl != null && iconUrl.isNotEmpty
          ? ClipOval(
              child: Image.network(
                iconUrl,
                width: 36,
                height: 36,
                fit: BoxFit.cover,
                color: iconUrl.endsWith('.svg') ? iconColor : null,
                colorBlendMode: BlendMode.srcIn,
                errorBuilder: (_, _, _) => Icon(
                  Platform.isIOS ? CupertinoIcons.sparkles : Icons.auto_awesome,
                  color: iconColor,
                  size: IconSize.modal,
                ),
              ),
            )
          : Icon(
              Platform.isIOS ? CupertinoIcons.sparkles : Icons.auto_awesome,
              color: iconColor,
              size: IconSize.modal,
            ),
    );
  }

  Widget _buildTogglePill({
    required bool isOn,
    required ConduitThemeExtension theme,
  }) {
    final Color trackColor = isOn
        ? theme.buttonPrimary.withValues(alpha: 0.9)
        : theme.cardBorder.withValues(alpha: 0.5);
    final Color thumbColor = isOn
        ? theme.buttonPrimaryText
        : theme.surfaceBackground.withValues(alpha: 0.9);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 42,
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppBorderRadius.round),
        color: trackColor,
      ),
      alignment: isOn ? Alignment.centerRight : Alignment.centerLeft,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: thumbColor,
          boxShadow: [
            BoxShadow(
              color: theme.buttonPrimary.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
      ),
    );
  }

  IconData _toolIconFor(Tool tool) {
    final name = tool.name.toLowerCase();
    if (name.contains('image') || name.contains('vision')) {
      return Platform.isIOS ? CupertinoIcons.photo : Icons.image;
    }
    if (name.contains('code') || name.contains('python')) {
      return Platform.isIOS
          ? CupertinoIcons.chevron_left_slash_chevron_right
          : Icons.code;
    }
    if (name.contains('calculator') || name.contains('math')) {
      return Icons.calculate;
    }
    if (name.contains('file') || name.contains('document')) {
      return Platform.isIOS ? CupertinoIcons.doc : Icons.description;
    }
    if (name.contains('api') || name.contains('request')) {
      return Icons.cloud;
    }
    if (name.contains('search')) {
      return Platform.isIOS ? CupertinoIcons.search : Icons.search;
    }
    return Platform.isIOS ? CupertinoIcons.square_grid_2x2 : Icons.extension;
  }

  Widget _buildInfoCard(String message) {
    final theme = context.conduitTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.cardBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.input),
        border: Border.all(
          color: theme.cardBorder.withValues(alpha: 0.6),
          width: BorderWidth.thin,
        ),
      ),
      child: Text(
        message,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
    );
  }

  Widget _buildOverflowAction({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    final theme = context.conduitTheme;
    final brightness = Theme.of(context).brightness;
    final VoidCallback? callback = onTap;
    final bool enabled = callback != null;
    final Color iconColor = enabled ? theme.buttonPrimary : theme.iconDisabled;
    final Color textColor = enabled
        ? theme.textPrimary
        : theme.textPrimary.withValues(alpha: Alpha.disabled);
    final Color background = theme.surfaceContainer.withValues(
      alpha: brightness == Brightness.dark ? 0.45 : 0.92,
    );
    final Color borderColor = theme.cardBorder.withValues(
      alpha: enabled ? 0.5 : 0.25,
    );
    final Color accent = theme.buttonPrimary.withValues(
      alpha: enabled ? Alpha.selected : Alpha.hover,
    );

    return Opacity(
      opacity: enabled ? 1.0 : Alpha.disabled,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppBorderRadius.card),
          onTap: callback == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  Future.microtask(callback);
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.xs,
              vertical: Spacing.sm,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppBorderRadius.card),
              border: Border.all(color: borderColor, width: BorderWidth.thin),
              color: background,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        accent,
                        theme.buttonPrimary.withValues(
                          alpha: enabled ? Alpha.highlight : Alpha.hover,
                        ),
                      ],
                    ),
                  ),
                  child: Icon(icon, color: iconColor, size: IconSize.modal),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: AppTypography.captionStyle.copyWith(
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
