import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/models/chat_message.dart';

import '../../../core/services/haptic_service.dart';

import 'package:conduit_core/services/settings_service.dart';

import 'package:conduit_core/features/chat/providers/streaming_haptic_memory.dart';
import 'package:conduit_core/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit_core/features/chat/views/chat_turn_render_state.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/markdown/renderer/markdown_style.dart';
import 'response_activity_indicator.dart';
import 'response_finish_transition.dart';

import 'package:conduit_core/models/response_animation.dart';

class StreamingTurnFooter extends ConsumerStatefulWidget {
  const StreamingTurnFooter({
    super.key,
    required this.message,
    this.suppressStreamingHaptics = false,
    this.inline = false,
    this.show = true,
    this.finishStyle,
    this.hermesActivityMark = false,
  });

  final ChatMessage message;
  final bool suppressStreamingHaptics;

  /// Allows the same indicator and exit to occupy an inline message slot.
  final bool inline;

  /// A waiting mark can leave on text arrival while the turn remains running.
  final bool show;
  final ResponseFinishStyle? finishStyle;
  final bool hermesActivityMark;

  @override
  ConsumerState<StreamingTurnFooter> createState() =>
      _StreamingTurnFooterState();
}

class _StreamingTurnFooterState extends ConsumerState<StreamingTurnFooter>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const Duration _switchDuration = responseFinishDuration;

  bool _disableAnimations = false;
  bool _didTriggerRunningHaptic = false;
  final _indicatorKey = GlobalKey<ResponseActivityIndicatorState>();
  late final AnimationController _finishClock;
  OverlayEntry? _finishOverlay;
  bool _wasShowing = false;
  int _finishGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _finishClock = AnimationController(vsync: this, duration: _switchDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.dismissed) _removeFinishOverlay();
      });
  }

  void _removeFinishOverlay() {
    _finishGeneration++;
    _finishOverlay?.remove();
    _finishOverlay?.dispose();
    _finishOverlay = null;
    _finishClock.stop();
  }

  void _playFinish() {
    _removeFinishOverlay();
    final settings = ref.read(appSettingsProvider);
    final finishStyle = widget.finishStyle ?? settings.responseFinishStyle;
    if (_disableAnimations ||
        settings.reduceMotion ||
        finishStyle == ResponseFinishStyle.clear) {
      return;
    }
    final indicator = _indicatorKey.currentState;
    final renderBox = _indicatorKey.currentContext?.findRenderObject();
    final overlay = Overlay.maybeOf(context);
    if (indicator == null ||
        renderBox is! RenderBox ||
        !renderBox.hasSize ||
        overlay == null) {
      return;
    }
    final overlayBox = overlay.context.findRenderObject();
    if (overlayBox is! RenderBox) return;
    final origin = overlayBox.globalToLocal(
      renderBox.localToGlobal(Offset.zero),
    );
    final bounds = origin & renderBox.size;
    if (!bounds.overlaps(Offset.zero & overlayBox.size)) return;
    final painter = indicator.snapshotPainter;
    final generation = _finishGeneration;
    // Paint a frozen outgoing mark in the overlay while the timeline swaps
    // its footer for message actions. The exit adds no temporary row height.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _finishGeneration) return;
      _finishClock.value = 1;
      _finishOverlay = OverlayEntry(
        builder: (context) {
          final mark = CustomPaint(
            key: const ValueKey('response-finish-frame'),
            size: bounds.size,
            painter: painter,
          );
          return Positioned.fromRect(
            rect: bounds,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: ResponseFinishTransition(
                  style: finishStyle,
                  progress: _finishClock,
                  child: mark,
                ),
              ),
            ),
          );
        },
      );
      overlay.insert(_finishOverlay!);
      _finishClock.reverse();
    });
  }

  @override
  void didUpdateWidget(covariant StreamingTurnFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id) {
      _removeFinishOverlay();
      _wasShowing = false;
      _didTriggerRunningHaptic = false;
    } else if (chatTurnPhaseForMessage(widget.message) ==
        ChatTurnPhase.failed) {
      _removeFinishOverlay();
    } else if (_wasShowing &&
        (!widget.show ||
            chatTurnPhaseForMessage(widget.message) ==
                ChatTurnPhase.completed)) {
      _playFinish();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = context.reduceMotion;
    if (_disableAnimations || !TickerMode.valuesOf(context).enabled) {
      _removeFinishOverlay();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive) {
      _removeFinishOverlay();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removeFinishOverlay();
    _finishClock.dispose();
    super.dispose();
  }

  void _syncRunningHaptic(bool shouldShow) {
    if (!shouldShow) {
      if (_didTriggerRunningHaptic) {
        ref
            .read(streamingHapticMemoryProvider)
            .rearmRunningIndicator(widget.message.id);
      }
      _didTriggerRunningHaptic = false;
      return;
    }
    if (_didTriggerRunningHaptic) {
      return;
    }
    _didTriggerRunningHaptic = true;
    final shouldTrigger = ref
        .read(streamingHapticMemoryProvider)
        .markFired(widget.message.id, StreamingHapticEvent.runningIndicator);
    if (!shouldTrigger) {
      return;
    }
    _streamingHaptic();
  }

  void _streamingHaptic() {
    final enabled =
        ref.read(streamingHapticsEnabledProvider) &&
        !widget.suppressStreamingHaptics;
    if (enabled) ConduitHaptics.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    // Queued/offline/stalled completions keep `isStreaming: true` on the
    // assistant row while the message body shows the retry banner. Suppress
    // the timeline typing indicator in that case — the old in-message footer
    // gated on `!hasQueuedCompletion` the same way.
    final queuedCompletionAsync = ref.watch(
      queuedCompletionInfoForMessageProvider(widget.message.id),
    );
    final hasQueuedCompletion =
        queuedCompletionAsync.hasValue && queuedCompletionAsync.value != null;
    final shouldShow =
        widget.show &&
        !hasQueuedCompletion &&
        shouldShowStreamingTurnFooter(message: widget.message);
    _syncRunningHaptic(shouldShow);
    _wasShowing = shouldShow;
    if (shouldShow) _removeFinishOverlay();

    final settings = ref.watch(appSettingsProvider);
    final reduceMotion = _disableAnimations || settings.reduceMotion;
    if (reduceMotion) _removeFinishOverlay();
    final usingSkill = responseIndicatorUsesSkill(widget.message);

    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : _switchDuration,
      reverseDuration: Duration.zero,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        final children = <Widget>[...previousChildren, ?currentChild];
        if (children.isEmpty) {
          return const SizedBox.shrink();
        }
        return Stack(
          alignment: AlignmentDirectional.topStart,
          children: children,
        );
      },
      child: shouldShow
          ? KeyedSubtree(
              key: const ValueKey('typing'),
              child: SizedBox(
                width: widget.inline
                    ? (widget.hermesActivityMark ? 12 : 28)
                    : double.infinity,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: widget.inline
                        ? EdgeInsets.zero
                        : EdgeInsets.only(
                            top: ConduitMarkdownStyle.fromTheme(context)
                                .paragraphSpacing,
                            bottom: Spacing.xs,
                          ),
                    child: Semantics(
                      label: usingSkill
                          ? AppLocalizations.of(context)
                                    ?.responseAnimationSkill ??
                                'Using a skill'
                          : AppLocalizations.of(context)
                                    ?.responseAnimationPreparing ??
                                'Preparing a response',
                      child: ResponseActivityIndicator(
                        key: _indicatorKey,
                        hermesDither: widget.hermesActivityMark,
                        style: usingSkill
                            ? settings.skillIndicatorStyle
                            : settings.thinkingIndicatorStyle,
                        speed: widget.hermesActivityMark
                            ? 1
                            : settings.animationSpeed,
                        size: widget.hermesActivityMark ? 12 : 28,
                        color: context.conduitTheme.textSecondary.withValues(
                          alpha: 0.75,
                        ),
                        animate: !reduceMotion,
                      ),
                    ),
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(key: ValueKey('streaming-turn-footer-empty')),
    );
  }
}

@visibleForTesting
bool shouldShowStreamingTurnFooter({required ChatMessage message}) {
  return chatTurnPhaseShowsRunningFooter(chatTurnPhaseForMessage(message));
}

/// Hermes emits a pending status per tool call, then marks it done on result.
/// Reasoning and completed tool history do not select the skill animation.
@visibleForTesting
bool responseIndicatorUsesSkill(ChatMessage message) =>
    message.statusHistory.any(
      (status) =>
          (status.action?.startsWith('hermes_tool_') ?? false) &&
          status.done != true,
    );
