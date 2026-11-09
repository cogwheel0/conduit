import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/models/chat_message.dart';

import '../../../core/services/haptic_service.dart';

import 'package:conduit_core/services/settings_service.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show streamingContentProvider;
import 'package:conduit_core/features/chat/providers/streaming_haptic_memory.dart';
import 'package:conduit_core/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit_core/features/chat/views/chat_turn_render_state.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/markdown/renderer/markdown_style.dart';
import 'chat_send_motion.dart';
import 'conduit_streaming_orbit.dart';
import 'thinking_status_label.dart';

/// The running footer's row: the height of a reply's action row, so the
/// settle swap between them is extent-neutral.
const double kStreamingTurnFooterRowHeight = 44;

class StreamingTurnFooter extends ConsumerStatefulWidget {
  const StreamingTurnFooter({
    super.key,
    required this.message,
    this.suppressStreamingHaptics = false,
  });

  final ChatMessage message;
  final bool suppressStreamingHaptics;

  @override
  ConsumerState<StreamingTurnFooter> createState() =>
      _StreamingTurnFooterState();
}

class _StreamingTurnFooterState extends ConsumerState<StreamingTurnFooter>
    with SingleTickerProviderStateMixin {
  /// A footer for a reply sent moments ago fades in after the sent message
  /// has risen into place; any other mount shows it at once.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: _switchDuration,
    value: 1,
  );
  Timer? _entranceTimer;

  @override
  void initState() {
    super.initState();
    final message = widget.message;
    if (WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations ||
        !isFreshChatContent(message.timestamp) ||
        !isChatEntranceAvailable(_entranceKey)) {
      return;
    }
    _entrance.value = 0;
  }

  String get _entranceKey => 'footer:${widget.message.id}';

  /// The pause and fade start once the footer is first on screen, not while
  /// the timeline hides a settling turn.
  void _startEntranceOnScreen() {
    if (_entranceTimer != null || _entrance.value >= 1) return;
    markChatEntranceShown(_entranceKey);
    _entranceTimer = startChatReplyEntrance(() {
      if (mounted) _entrance.forward();
    });
  }

  @override
  void dispose() {
    _entranceTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  static const Duration _switchDuration = Duration(milliseconds: 200);

  bool _disableAnimations = false;
  bool _didTriggerRunningHaptic = false;

  @override
  void didUpdateWidget(covariant StreamingTurnFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id) {
      _didTriggerRunningHaptic = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = context.reduceMotion;
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
        !hasQueuedCompletion &&
        shouldShowStreamingTurnFooter(message: widget.message);
    _syncRunningHaptic(shouldShow);
    final hasStreamedContent = ref.watch(
      streamingContentProvider.select(
        (content) => content != null && content.trim().isNotEmpty,
      ),
    );
    final showOrbit =
        shouldShow &&
        shouldShowStreamingOrbit(
          message: widget.message,
          hasStreamedContent: hasStreamedContent,
        );

    return ChatFirstPaintListener(
      onFirstPaint: _startEntranceOnScreen,
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _entrance, curve: Curves.easeOut),
        child: AnimatedSwitcher(
          duration: _disableAnimations ? Duration.zero : _switchDuration,
          reverseDuration: _disableAnimations ? Duration.zero : _switchDuration,
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
                    width: double.infinity,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: ConduitMarkdownStyle.fromTheme(context)
                              .paragraphSpacing,
                        ),
                        // As tall as the reply's action row (44 pt targets) that
                        // replaces it at settle, with the orbit centred where those
                        // glyphs will sit, so the swap moves nothing.
                        child: SizedBox(
                          height: kStreamingTurnFooterRowHeight,
                          // The row keeps its place for the action row that
                          // replaces it; the orbit in it shows only while the
                          // reply works with nothing to read (see
                          // shouldShowStreamingOrbit). Before the first words
                          // "Thinking…" stands in the reply's first line, and
                          // once text streams the text itself, with Stop in
                          // the composer, says the reply is still coming: a
                          // spinner a line below it would float unattached.
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            widthFactor: 1,
                            child: AnimatedOpacity(
                              key: const ValueKey(
                                'streaming-turn-orbit-opacity',
                              ),
                              opacity: showOrbit ? 1 : 0,
                              duration: _disableAnimations
                                  ? Duration.zero
                                  : _switchDuration,
                              curve: Curves.easeOut,
                              child: RepaintBoundary(
                                child: ConduitStreamingOrbit(
                                  size: 28,
                                  color: context.conduitTheme.textSecondary
                                      .withValues(alpha: 0.75),
                                  animate: !_disableAnimations && showOrbit,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(
                  key: ValueKey('streaming-turn-footer-empty'),
                ),
        ),
      ),
    );
  }
}

@visibleForTesting
bool shouldShowStreamingTurnFooter({required ChatMessage message}) {
  return chatTurnPhaseShowsRunningFooter(chatTurnPhaseForMessage(message));
}

/// Whether the running footer spells out "Thinking…": only while the reply
/// has nothing else on screen. Text, a visible status row, files, or code
/// runs each say more than the label would, and a streamed reasoning block
/// arrives as content with its own "Thinking…" header.
@visibleForTesting
bool shouldShowThinkingLabel({
  required ChatMessage message,
  required bool hasStreamedContent,
}) {
  if (hasStreamedContent || message.content.trim().isNotEmpty) return false;
  if (message.statusHistory.any((update) => update.hidden != true)) {
    return false;
  }
  if (message.files?.isNotEmpty ?? false) return false;
  if (message.codeExecutions.isNotEmpty) return false;
  return true;
}

/// Whether the running footer shows its orbit: only while the reply works
/// with no text on screen and no "Thinking…" label, such as while a visible
/// status row, files or a code run stand in for the answer. Once any text
/// shows, the growing text and the composer's Stop already say the reply is
/// still coming.
@visibleForTesting
bool shouldShowStreamingOrbit({
  required ChatMessage message,
  required bool hasStreamedContent,
}) {
  if (hasStreamedContent || message.content.trim().isNotEmpty) return false;
  return !shouldShowThinkingLabel(
    message: message,
    hasStreamedContent: hasStreamedContent,
  );
}

/// Whether a reply shows "Thinking…" in place of its first line: while its
/// turn runs and it has shown nothing yet (see [shouldShowThinkingLabel]).
bool shouldShowReplyFirstLineThinking({
  required ChatMessage message,
  required String displayedContent,
}) =>
    shouldShowStreamingTurnFooter(message: message) &&
    shouldShowThinkingLabel(
      message: message,
      hasStreamedContent: displayedContent.trim().isNotEmpty,
    );

/// "Thinking…" holding the place of a reply's first line until the reply
/// shows anything, then cross-fading with that line where it stands.
///
/// The label is set in the reply's own body type and line height and sits at
/// the top of the body, so the first words appear exactly where it was:
/// nothing shifts when the answer starts. The body below is [child], which
/// fades in on its own; this only fades the label out over it. Reduce Motion
/// swaps them at once.
class ReplyFirstLineThinking extends StatelessWidget {
  const ReplyFirstLineThinking({
    super.key,
    required this.startedAt,
    required this.showing,
    required this.child,
  });

  /// When the reply was requested; the label's elapsed time counts from here.
  final DateTime startedAt;
  final bool showing;
  final Widget child;

  static const Duration fadeDuration = Duration(milliseconds: 150);

  /// The label leaves almost at once when the first words arrive: they fade
  /// in at the same place, and two lines of text fading through each other
  /// read as garbled for those frames.
  static const Duration exitDuration = Duration(milliseconds: 60);
  static const Key labelKey = ValueKey('reply-first-line-thinking');

  @override
  Widget build(BuildContext context) {
    final reduceMotion = context.reduceMotion;
    return Stack(
      alignment: AlignmentDirectional.topStart,
      children: [
        child,
        AnimatedSwitcher(
          duration: reduceMotion ? Duration.zero : fadeDuration,
          reverseDuration: reduceMotion ? Duration.zero : exitDuration,
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: AlignmentDirectional.topStart,
            children: [...previousChildren, ?currentChild],
          ),
          child: showing
              ? ThinkingStatusLabel(
                  key: labelKey,
                  startedAt: startedAt,
                  animate: !reduceMotion,
                  style: ConduitMarkdownStyle.fromTheme(context).body,
                )
              : const SizedBox.shrink(
                  key: ValueKey('reply-first-line-thinking-empty'),
                ),
        ),
      ],
    );
  }
}
