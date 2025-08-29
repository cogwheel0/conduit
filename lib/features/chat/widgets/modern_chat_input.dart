import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../../../shared/theme/theme_extensions.dart';
// app_theme not required here; using theme extension tokens
import '../../../shared/widgets/sheet_handle.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io' show Platform;
import 'dart:async';
import '../providers/chat_providers.dart';
import '../../tools/widgets/unified_tools_modal.dart';
import '../../tools/providers/tools_providers.dart';
import '../../../core/providers/app_providers.dart';
import '../../chat/services/voice_input_service.dart';

import '../../../shared/utils/platform_utils.dart';
import '../../../core/utils/debug_logger.dart';
import 'package:conduit/l10n/app_localizations.dart';

class ModernChatInput extends ConsumerStatefulWidget {
  final Function(String) onSendMessage;
  final bool enabled;
  final Function()? onVoiceInput;
  final Function()? onFileAttachment;
  final Function()? onImageAttachment;
  final Function()? onCameraCapture;

  const ModernChatInput({
    super.key,
    required this.onSendMessage,
    this.enabled = true,
    this.onVoiceInput,
    this.onFileAttachment,
    this.onImageAttachment,
    this.onCameraCapture,
  });

  @override
  ConsumerState<ModernChatInput> createState() => _ModernChatInputState();
}

class _MicButton extends StatelessWidget {
  final bool isRecording;
  final int intensity; // 0..10
  final VoidCallback? onTap;
  final String tooltip;

  const _MicButton({
    required this.isRecording,
    required this.intensity,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final Color borderColor = isRecording
        ? context.conduitTheme.buttonPrimary
        : context.conduitTheme.cardBorder;
    final Color bgColor = isRecording
        ? context.conduitTheme.buttonPrimary.withValues(
            alpha: Alpha.buttonHover,
          )
        : context.conduitTheme.cardBackground;
    final Color iconColor = isRecording
        ? context.conduitTheme.buttonPrimaryText
        : context.conduitTheme.textPrimary.withValues(alpha: Alpha.strong);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppBorderRadius.round),
          side: BorderSide(color: borderColor, width: BorderWidth.regular),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppBorderRadius.round),
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          child: Container(
            width: TouchTarget.comfortable,
            height: TouchTarget.comfortable,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(AppBorderRadius.round),
              boxShadow: ConduitShadows.button,
            ),
            child: Center(
              child: isRecording
                  ? _WaveformBars(intensity: intensity, color: iconColor)
                  : Icon(
                      Platform.isIOS ? CupertinoIcons.mic_fill : Icons.mic,
                      size: IconSize.medium,
                      color: iconColor,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformBars extends StatelessWidget {
  final int intensity; // 0..10
  final Color color;

  const _WaveformBars({required this.intensity, required this.color});

  @override
  Widget build(BuildContext context) {
    // 5 bars with varying base heights; scale with intensity
    final double unit = (intensity.clamp(0, 10)) / 10.0; // 0..1
    final List<double> factors = [0.4, 0.7, 1.0, 0.7, 0.4];
    final double maxHeight = IconSize.medium; // ~24px
    // Keep bars within the available width to avoid RenderFlex overflow
    final double width = 14.0; // tighter than 16 to accommodate padding
    final double barWidth = 2.0;
    final double gap = 1.0;
    return SizedBox(
      width: width,
      height: maxHeight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(5, (i) {
          final double h = (maxHeight * (factors[i] * (0.3 + 0.7 * unit)))
              .clamp(4.0, maxHeight);
          return Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0.0 : gap),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: barWidth,
              height: h,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2.0),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _ModernChatInputState extends ConsumerState<ModernChatInput>
    with TickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isRecording = false;
  bool _isExpanded = true; // Start expanded for better UX
  // TODO: Implement voice input functionality
  // final String _voiceInputText = '';
  bool _hasText = false; // track locally without rebuilding on each keystroke
  StreamSubscription<String>? _voiceStreamSubscription;
  late AnimationController _expandController;
  late AnimationController _pulseController;
  Timer? _blurCollapseTimer;
  bool _hasAutoFocusedOnce = false;
  late VoiceInputService _voiceService;
  StreamSubscription<int>? _intensitySub;
  StreamSubscription<String>? _textSub;
  int _intensity = 0; // 0..10 from service
  String _baseTextAtStart = '';
  bool _isDeactivated = false;
  int _lastHandledFocusTick = 0;
  int _lastHandledVoiceTick = 0;

  @override
  void initState() {
    super.initState();
    _voiceService = ref.read(voiceInputServiceProvider);
    _expandController = AnimationController(
      duration:
          AnimationDuration.fast, // Faster animation for better responsiveness
      vsync: this,
      value: 1.0, // Start expanded
    );
    _pulseController = AnimationController(
      duration: AnimationDuration.slow,
      vsync: this,
    );

    // Apply any prefilled text on first frame (focus/expand handled via inputFocusTrigger)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDeactivated) return;
      final text = ref.read(prefilledInputTextProvider);
      if (text != null && text.isNotEmpty) {
        _controller.text = text;
        _controller.selection = TextSelection.collapsed(offset: text.length);
        // Clear after applying so it doesn't re-apply on rebuilds
        ref.read(prefilledInputTextProvider.notifier).state = null;
      }
    });

    // Removed ref.listen here; it must be used from build in this Riverpod version

    // Listen for text changes and update only when emptiness flips
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _isDeactivated) return;
          setState(() => _hasText = has);
          // Intelligent expansion: expand when user starts typing
          if (has && !_isExpanded) {
            _setExpanded(true);
          }
        });
      }
    });

    // Intelligent expand/collapse around focus changes
    _focusNode.addListener(() {
      // Cancel any pending blur-driven collapse
      _blurCollapseTimer?.cancel();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDeactivated) return;
        final hasFocus = _focusNode.hasFocus;
        if (hasFocus) {
          if (!_isExpanded) _setExpanded(true);
        } else {
          // Defer collapse slightly to avoid IME show/hide race conditions
          _blurCollapseTimer = Timer(const Duration(milliseconds: 160), () {
            if (!mounted || _isDeactivated) return;
            if (_focusNode.hasFocus) return; // focus came back
            // Collapse only when keyboard is fully hidden to avoid flicker
            final keyboardVisible =
                MediaQuery.of(context).viewInsets.bottom > 0;
            if (keyboardVisible) return;
            final has = _controller.text.trim().isNotEmpty;
            if (!has && _isExpanded) {
              _setExpanded(false);
            }
          });
        }
      });
    });

    // Let autofocus handle the focus - no manual intervention
    // The TextField's autofocus: true should handle focus and keyboard automatically
    // Additionally, request focus after first frame to ensure reliability across platforms
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDeactivated) return;
      if (!_hasAutoFocusedOnce && widget.enabled) {
        _ensureFocusedIfEnabled();
        _hasAutoFocusedOnce = true;
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _expandController.dispose();
    _pulseController.dispose();
    _blurCollapseTimer?.cancel();
    _voiceStreamSubscription?.cancel();
    _intensitySub?.cancel();
    _textSub?.cancel();
    _voiceService.stopListening();
    super.dispose();
  }

  void _ensureFocusedIfEnabled() {
    if (!widget.enabled) return;
    if (!_focusNode.hasFocus) {
      // Use FocusNode directly to avoid depending on Inherited widgets
      _focusNode.requestFocus();
    }
  }

  @override
  void deactivate() {
    _isDeactivated = true;
    _blurCollapseTimer?.cancel();
    _expandController.stop();
    _pulseController.stop();
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
    if (widget.enabled && !oldWidget.enabled && !_hasAutoFocusedOnce) {
      // Became enabled (e.g., after selecting a model) → focus the input
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDeactivated) return;
        _ensureFocusedIfEnabled();
        _hasAutoFocusedOnce = true;
      });
    }
    if (!widget.enabled && oldWidget.enabled) {
      // Became disabled → collapse and hide keyboard
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDeactivated) return;
        if (_isExpanded) _setExpanded(false);
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
    // Keep tools and web search enabled for the conversation
    // Keep input expanded and focused for better UX - don't dismiss keyboard
    // KeyboardUtils.dismissKeyboard(context);
    // _setExpanded(false);
  }

  void _setExpanded(bool expanded) {
    if (!mounted || _isDeactivated || _isExpanded == expanded) return;
    setState(() {
      _isExpanded = expanded;
    });
    if (expanded) {
      _expandController.forward();
    } else {
      _expandController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen for prefilled text changes safely from build
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
          ref.read(prefilledInputTextProvider.notifier).state = null;
        } catch (_) {}
      });
    });

    // Check if assistant is currently generating by checking last assistant message streaming
    final messages = ref.watch(chatMessagesProvider);
    final isGenerating =
        messages.isNotEmpty &&
        messages.last.role == 'assistant' &&
        messages.last.isStreaming;
    final stopGeneration = ref.read(stopGenerationProvider);

    final webSearchEnabled = ref.watch(webSearchEnabledProvider);
    final imageGenEnabled = ref.watch(imageGenerationEnabledProvider);
    final imageGenAvailable = ref.watch(imageGenerationAvailableProvider);
    final voiceAvailableAsync = ref.watch(voiceInputAvailableProvider);
    final bool voiceAvailable = voiceAvailableAsync.maybeWhen(
      data: (v) => v,
      orElse: () => false,
    );

    // React to external focus requests (e.g., from share prefill)
    final focusTick = ref.watch(inputFocusTriggerProvider);
    if (focusTick != _lastHandledFocusTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDeactivated) return;
        // Do not steal focus if another input currently has primary focus
        final currentFocus = FocusManager.instance.primaryFocus;
        final anotherHasFocus =
            currentFocus != null && currentFocus != _focusNode;
        if (!anotherHasFocus) {
          _ensureFocusedIfEnabled();
          if (!_isExpanded) _setExpanded(true);
        }
        _lastHandledFocusTick = focusTick;
      });
    }

    // React to external voice input requests (e.g., from ASSIST intent)
    final voiceTick = ref.watch(voiceInputTriggerProvider);
    if (voiceTick != _lastHandledVoiceTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDeactivated) return;
        if (widget.enabled && voiceAvailable && !_isRecording) {
          _startVoice();
        }
        _lastHandledVoiceTick = voiceTick;
      });
    }

    return Container(
      // Transparent wrapper so rounded corners are visible against page background
      color: Colors.transparent,
      padding: EdgeInsets.only(
        left: 0,
        right: 0,
        top: Spacing.xs.toDouble(),
        bottom: 0,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Main input area with unified 2-row design
          Container(
            decoration: BoxDecoration(
              color: context.conduitTheme.inputBackground,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppBorderRadius.xl),
                bottom: Radius.circular(0),
              ),
              border: Border(
                top: BorderSide(
                  color: context.conduitTheme.dividerColor,
                  width: BorderWidth.regular,
                ),
                left: BorderSide(
                  color: context.conduitTheme.dividerColor,
                  width: BorderWidth.regular,
                ),
                right: BorderSide(
                  color: context.conduitTheme.dividerColor,
                  width: BorderWidth.regular,
                ),
              ),
              boxShadow: ConduitShadows.input,
            ),
            width: double.infinity,
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  // cap the input area to 40% of screen height to avoid bottom overflow
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: AnimatedSize(
                  duration: AnimationDuration
                      .fast, // Faster for better responsiveness
                  curve: Curves.fastOutSlowIn, // More efficient curve
                  alignment: Alignment.topCenter,
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: RepaintBoundary(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Collapsed/Expanded top row: text input with left/right buttons in collapsed
                          Padding(
                            padding: const EdgeInsets.only(
                              left: Spacing.inputPadding,
                              right: Spacing.inputPadding,
                              top: Spacing.inputPadding,
                              bottom: Spacing.inputPadding,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                if (!_isExpanded) ...[
                                  _buildRoundButton(
                                    icon: Icons.add,
                                    onTap: widget.enabled
                                        ? _showAttachmentOptions
                                        : null,
                                    tooltip: AppLocalizations.of(
                                      context,
                                    )!.addAttachment,
                                    showBackground: false,
                                    iconSize: IconSize.large + 2.0,
                                  ),
                                  const SizedBox(width: Spacing.xs),
                                ] else ...[
                                  SizedBox(width: Spacing.xs),
                                ],
                                // Text input expands to fill
                                Expanded(
                                  child: Semantics(
                                    textField: true,
                                    label: AppLocalizations.of(
                                      context,
                                    )!.messageInputLabel,
                                    hint: AppLocalizations.of(
                                      context,
                                    )!.messageInputHint,
                                    child: TextField(
                                      controller: _controller,
                                      focusNode: _focusNode,
                                      enabled: widget.enabled,
                                      autofocus: false,
                                      maxLines: _isExpanded ? null : 1,
                                      keyboardType: TextInputType.multiline,
                                      textCapitalization:
                                          TextCapitalization.sentences,
                                      textInputAction: TextInputAction.newline,
                                      showCursor: true,
                                      cursorColor:
                                          context.conduitTheme.inputText,
                                      style: AppTypography.chatMessageStyle
                                          .copyWith(
                                            color: _isRecording
                                                ? context
                                                      .conduitTheme
                                                      .inputPlaceholder
                                                : context
                                                      .conduitTheme
                                                      .inputText,
                                            fontStyle: _isRecording
                                                ? FontStyle.italic
                                                : FontStyle.normal,
                                            fontWeight: _isRecording
                                                ? FontWeight.w500
                                                : FontWeight.w400,
                                          ),
                                      decoration: InputDecoration(
                                        hintText: AppLocalizations.of(
                                          context,
                                        )!.messageHintText,
                                        hintStyle: TextStyle(
                                          color: context
                                              .conduitTheme
                                              .inputPlaceholder,
                                          fontSize: AppTypography.bodyLarge,
                                          fontWeight: _isRecording
                                              ? FontWeight.w500
                                              : FontWeight.w400,
                                          fontStyle: _isRecording
                                              ? FontStyle.italic
                                              : FontStyle.normal,
                                        ),
                                        // Ensure the text field background matches its parent container
                                        // and does not use the global InputDecorationTheme fill
                                        filled: false,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        errorBorder: InputBorder.none,
                                        disabledBorder: InputBorder.none,
                                        contentPadding: EdgeInsets.zero,
                                        isDense: true,
                                        alignLabelWithHint: true,
                                      ),
                                      // Removed onChanged setState to reduce rebuilds
                                      onSubmitted: (_) => _sendMessage(),
                                      onTap: () {
                                        if (!widget.enabled) return;
                                        if (!_isExpanded) {
                                          _setExpanded(true);
                                          WidgetsBinding.instance
                                              .addPostFrameCallback((_) {
                                                if (!mounted) return;
                                                _ensureFocusedIfEnabled();
                                              });
                                        } else {
                                          _ensureFocusedIfEnabled();
                                        }
                                      },
                                    ),
                                  ),
                                ),
                                if (!_isExpanded) ...[
                                  const SizedBox(width: Spacing.sm),
                                  // Primary action button (Send/Stop) when collapsed
                                  _buildPrimaryButton(
                                    _hasText,
                                    isGenerating,
                                    stopGeneration,
                                  ),
                                ],
                              ],
                            ),
                          ),

                          // Expanded bottom row with additional options
                          if (_isExpanded) ...[
                            Container(
                              padding: const EdgeInsets.only(
                                left: Spacing.inputPadding,
                                right: Spacing.inputPadding,
                                bottom: Spacing.inputPadding,
                              ),
                              child: FadeTransition(
                                opacity: _expandController,
                                child: Row(
                                  children: [
                                    _buildRoundButton(
                                      icon: Icons.add,
                                      onTap: widget.enabled && !_isRecording
                                          ? _showAttachmentOptions
                                          : null,
                                      tooltip: AppLocalizations.of(
                                        context,
                                      )!.addAttachment,
                                      showBackground: false,
                                      iconSize: IconSize.large + 2.0,
                                    ),
                                    const SizedBox(width: Spacing.xs),
                                    // Quick pills: no scroll, clip text within fixed max width
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Expanded(
                                            flex: 2,
                                            child: _buildPillButton(
                                              icon: Platform.isIOS
                                                  ? CupertinoIcons.search
                                                  : Icons.search,
                                              label: AppLocalizations.of(
                                                context,
                                              )!.web,
                                              isActive: webSearchEnabled,
                                              onTap:
                                                  widget.enabled &&
                                                      !_isRecording
                                                  ? () {
                                                      ref
                                                              .read(
                                                                webSearchEnabledProvider
                                                                    .notifier,
                                                              )
                                                              .state =
                                                          !webSearchEnabled;
                                                    }
                                                  : null,
                                            ),
                                          ),
                                          if (imageGenAvailable) ...[
                                            const SizedBox(width: Spacing.xs),
                                            Expanded(
                                              flex: 3,
                                              child: _buildPillButton(
                                                icon: Platform.isIOS
                                                    ? CupertinoIcons.photo
                                                    : Icons.image,
                                                label: AppLocalizations.of(
                                                  context,
                                                )!.imageGen,
                                                isActive: imageGenEnabled,
                                                onTap:
                                                    widget.enabled &&
                                                        !_isRecording
                                                    ? () {
                                                        ref
                                                                .read(
                                                                  imageGenerationEnabledProvider
                                                                      .notifier,
                                                                )
                                                                .state =
                                                            !imageGenEnabled;
                                                      }
                                                    : null,
                                              ),
                                            ),
                                          ],
                                          const SizedBox(width: Spacing.xs),
                                          _buildRoundButton(
                                            icon: Icons.more_horiz,
                                            onTap:
                                                widget.enabled && !_isRecording
                                                ? _showUnifiedToolsModal
                                                : null,
                                            tooltip: AppLocalizations.of(
                                              context,
                                            )!.tools,
                                            isActive:
                                                ref
                                                    .watch(
                                                      selectedToolIdsProvider,
                                                    )
                                                    .isNotEmpty ||
                                                webSearchEnabled ||
                                                imageGenEnabled,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: Spacing.xs),
                                    // Mic + Send cluster pinned to the right
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // Microphone button: inline voice input toggle with animated intensity ring
                                        Builder(
                                          builder: (context) {
                                            const double buttonSize =
                                                TouchTarget.comfortable;
                                            final double t = _isRecording
                                                ? (_intensity.clamp(0, 10) /
                                                      10.0)
                                                : 0.0;
                                            final double ringMaxExtra = 16.0;
                                            final double ringSize =
                                                buttonSize + (ringMaxExtra * t);
                                            final double ringOpacity =
                                                0.15 + (0.35 * t);

                                            return SizedBox(
                                              width: buttonSize,
                                              height: buttonSize,
                                              child: Stack(
                                                alignment: Alignment.center,
                                                children: [
                                                  AnimatedContainer(
                                                    duration: const Duration(
                                                      milliseconds: 120,
                                                    ),
                                                    width: ringSize,
                                                    height: ringSize,
                                                    decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      color: context
                                                          .conduitTheme
                                                          .buttonPrimary
                                                          .withValues(
                                                            alpha: ringOpacity,
                                                          ),
                                                    ),
                                                  ),
                                                  Transform.scale(
                                                    scale: _isRecording
                                                        ? 1.0 +
                                                              (_intensity.clamp(
                                                                    0,
                                                                    10,
                                                                  ) /
                                                                  200)
                                                        : 1.0,
                                                    child: _MicButton(
                                                      isRecording: _isRecording,
                                                      intensity: _intensity,
                                                      onTap:
                                                          (widget.enabled &&
                                                              voiceAvailable)
                                                          ? _toggleVoice
                                                          : null,
                                                      tooltip:
                                                          AppLocalizations.of(
                                                            context,
                                                          )!.voiceInput,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                        const SizedBox(width: Spacing.xs),
                                        // Primary action button (Send/Stop) when expanded
                                        _buildPrimaryButton(
                                          _hasText,
                                          isGenerating,
                                          stopGeneration,
                                        ),
                                      ],
                                    ),
                                    // Debug button for testing on-device STT (enable by changing false to true)
                                    // ignore: dead_code
                                    if (false) ...[
                                      const SizedBox(width: Spacing.sm),
                                      _buildRoundButton(
                                        icon: Icons.bug_report,
                                        onTap: widget.enabled
                                            ? () async {
                                                final result =
                                                    await _voiceService
                                                        .testOnDeviceStt();
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        'STT Test: $result',
                                                      ),
                                                      duration: const Duration(
                                                        seconds: 5,
                                                      ),
                                                    ),
                                                  );
                                                }
                                              }
                                            : null,
                                        tooltip: 'Test On-Device STT',
                                      ),
                                    ],
                                    // removed duplicate send button; now only in right cluster
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryButton(
    bool hasText,
    bool isGenerating,
    void Function() stopGeneration,
  ) {
    // Spec: 48px touch target, circular radius, md icon size
    const double buttonSize = TouchTarget.comfortable; // 48.0
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
                boxShadow: ConduitShadows.button,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: buttonSize - 18,
                    height: buttonSize - 18,
                    child: CircularProgressIndicator(
                      strokeWidth: BorderWidth.medium,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        context.conduitTheme.error,
                      ),
                    ),
                  ),
                  Icon(
                    Platform.isIOS ? CupertinoIcons.stop_fill : Icons.stop,
                    size: IconSize.medium,
                    color: context.conduitTheme.error,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Default SEND variant
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
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
              side: BorderSide(
                color: enabled
                    ? context.conduitTheme.cardBorder
                    : context.conduitTheme.cardBorder.withValues(
                        alpha: Alpha.medium,
                      ),
                width: BorderWidth.regular,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(radius),
              onTap: enabled
                  ? () {
                      PlatformUtils.lightHaptic();
                      _sendMessage();
                    }
                  : null,
              child: Container(
                width: buttonSize,
                height: buttonSize,
                decoration: BoxDecoration(
                  color: context.conduitTheme.cardBackground,
                  borderRadius: BorderRadius.circular(radius),
                  boxShadow: ConduitShadows.button,
                ),
                child: Icon(
                  Platform.isIOS ? CupertinoIcons.arrow_up : Icons.arrow_upward,
                  size: IconSize.medium,
                  color: enabled
                      ? context.conduitTheme.textPrimary
                      : context.conduitTheme.textPrimary.withValues(
                          alpha: Alpha.disabled,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoundButton({
    required IconData icon,
    VoidCallback? onTap,
    String? tooltip,
    bool isActive = false,
    bool showBackground = true,
    double? iconSize,
  }) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppBorderRadius.xl),
          side: BorderSide(
            color: isActive
                ? context.conduitTheme.buttonPrimary
                : showBackground
                ? context.conduitTheme.cardBorder
                : Colors.transparent,
            width: BorderWidth.regular,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppBorderRadius.xl),
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap();
                },
          child: Container(
            width: TouchTarget.comfortable,
            height: TouchTarget.comfortable,
            decoration: BoxDecoration(
              color: isActive
                  ? context.conduitTheme.buttonPrimary
                  : showBackground
                  ? context.conduitTheme.cardBackground
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AppBorderRadius.xl),
              boxShadow: (isActive || showBackground)
                  ? ConduitShadows.button
                  : null,
            ),
            child: Icon(
              icon,
              size: iconSize ?? IconSize.medium,
              color: widget.enabled
                  ? (isActive
                        ? context.conduitTheme.buttonPrimaryText
                        : context.conduitTheme.textPrimary.withValues(
                            alpha: Alpha.strong,
                          ))
                  : context.conduitTheme.textPrimary.withValues(
                      alpha: Alpha.disabled,
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
  }) {
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppBorderRadius.xl),
        side: BorderSide(
          color: isActive
              ? context.conduitTheme.buttonPrimary
              : context.conduitTheme.cardBorder,
          width: BorderWidth.regular,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppBorderRadius.xl),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap();
              },
        child: Container(
          height: TouchTarget.comfortable, // exact height match
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          decoration: BoxDecoration(
            // Subtle primary tint when active for clearer affordance
            color: isActive
                ? context.conduitTheme.buttonPrimary.withValues(
                    alpha: Alpha.buttonHover + 0.04,
                  )
                : context.conduitTheme.cardBackground,
            borderRadius: BorderRadius.circular(AppBorderRadius.xl),
            // No elevation to match modal chips
            boxShadow: ConduitShadows.button,
          ),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: AppTypography.labelStyle.copyWith(
                color: isActive
                    ? context.conduitTheme.buttonPrimary
                    : context.conduitTheme.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showAttachmentOptions() {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: context.conduitTheme.surfaceBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.bottomSheet),
          ),
          border: Border.all(
            color: context.conduitTheme.dividerColor,
            width: BorderWidth.regular,
          ),
          boxShadow: ConduitShadows.modal,
        ),
        padding: const EdgeInsets.all(Spacing.bottomSheetPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar (standardized)
            const SheetHandle(),
            const SizedBox(height: Spacing.lg),

            // Options grid
            Row(
              children: [
                Expanded(
                  child: _buildAttachmentOption(
                    icon: Platform.isIOS
                        ? CupertinoIcons.doc
                        : Icons.attach_file,
                    label: AppLocalizations.of(context)!.file,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      Navigator.pop(context); // Close modal
                      widget.onFileAttachment?.call();
                    },
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: _buildAttachmentOption(
                    icon: Platform.isIOS ? CupertinoIcons.photo : Icons.image,
                    label: AppLocalizations.of(context)!.photo,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      Navigator.pop(context); // Close modal
                      widget.onImageAttachment?.call();
                    },
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: _buildAttachmentOption(
                    icon: Platform.isIOS
                        ? CupertinoIcons.camera
                        : Icons.camera_alt,
                    label: AppLocalizations.of(context)!.camera,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      Navigator.pop(context); // Close modal
                      widget.onCameraCapture?.call();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.lg),
          ],
        ),
      ),
    );
  }

  void _showUnifiedToolsModal() {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => const UnifiedToolsModal(),
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
      if (!ok) {
        _showVoiceUnavailable(
          AppLocalizations.of(context)?.errorMessage ??
              'Voice input unavailable',
        );
        return;
      }
      // Centralized permission + start
      final stream = await _voiceService.beginListening();
      setState(() {
        _isRecording = true;
        _baseTextAtStart = _controller.text;
      });
      _intensitySub?.cancel();
      _intensitySub = _voiceService.intensityStream.listen((value) {
        if (!mounted) return;
        setState(() => _intensity = value);
      });
      _textSub?.cancel();
      _textSub = stream.listen(
        (text) async {
          final updated =
              (_baseTextAtStart.isEmpty
                  ? ''
                  : (_baseTextAtStart.trimRight() + ' ')) +
              text;
          _controller.value = TextEditingValue(
            text: updated,
            selection: TextSelection.collapsed(offset: updated.length),
          );
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _isRecording = false);
          _intensitySub?.cancel();
          _intensitySub = null;

          // Auto-send message if this was triggered by ASSIST intent
          final isAssistIntentSession = ref.read(
            isAssistIntentVoiceSessionProvider,
          );
          if (isAssistIntentSession) {
            DebugLogger.log(
              'Voice input completed for ASSIST intent - auto-sending message',
            );
            // Reset the flag
            ref.read(isAssistIntentVoiceSessionProvider.notifier).state = false;
            // Auto-send the message after a short delay to ensure text is updated
            Future.delayed(const Duration(milliseconds: 100), () {
              if (!mounted) return;
              final text = _controller.text.trim();
              if (text.isNotEmpty) {
                _sendMessage();
              }
            });
          }
        },
        onError: (_) {
          if (!mounted) return;
          setState(() => _isRecording = false);
          _intensitySub?.cancel();
          _intensitySub = null;

          // Reset ASSIST intent flag on error
          ref.read(isAssistIntentVoiceSessionProvider.notifier).state = false;
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
    _intensitySub?.cancel();
    _intensitySub = null;
    await _voiceService.stopListening();
    if (!mounted) return;
    setState(() => _isRecording = false);
    HapticFeedback.selectionClick();

    // Reset ASSIST intent flag when manually stopping voice input
    ref.read(isAssistIntentVoiceSessionProvider.notifier).state = false;
  }

  // Server transcription removed; only on-device STT updates the input text

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

  Widget _buildAttachmentOption({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap();
              },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: context.conduitTheme.cardBackground,
                borderRadius: BorderRadius.circular(AppBorderRadius.lg),
                border: Border.all(
                  color: context.conduitTheme.cardBorder,
                  width: BorderWidth.regular,
                ),
              ),
              child: Icon(
                icon,
                color: context.conduitTheme.iconPrimary,
                size: IconSize.xl,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              label,
              style: AppTypography.labelStyle.copyWith(
                color: context.conduitTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
