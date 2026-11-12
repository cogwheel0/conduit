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

class _StreamingTurnFooterState extends ConsumerState<StreamingTurnFooter> {
  static const Duration _switchDuration = Duration(milliseconds: 200);
  static const Duration _labelSwitchDuration = Duration(milliseconds: 160);

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
    final showThinkingLabel =
        shouldShow &&
        shouldShowThinkingLabel(
          message: widget.message,
          hasStreamedContent: hasStreamedContent,
        );

    return AnimatedSwitcher(
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
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RepaintBoundary(
                            child: ConduitStreamingOrbit(
                              size: 28,
                              color: context.conduitTheme.textSecondary
                                  .withValues(alpha: 0.75),
                              animate: !_disableAnimations,
                            ),
                          ),
                          // Until the reply shows anything, the orbit alone is
                          // too quiet for a wait of several seconds. The label
                          // leaves as soon as text, a status, or a streamed
                          // reasoning block (with its own "Thinking…") appears;
                          // the orbit stays put, so nothing shifts.
                          Flexible(
                            child: AnimatedSwitcher(
                              duration: _disableAnimations
                                  ? Duration.zero
                                  : _labelSwitchDuration,
                              switchInCurve: Curves.easeOut,
                              switchOutCurve: Curves.easeIn,
                              layoutBuilder: (currentChild, previousChildren) =>
                                  Stack(
                                    alignment: AlignmentDirectional.centerStart,
                                    children: [
                                      ...previousChildren,
                                      ?currentChild,
                                    ],
                                  ),
                              child: showThinkingLabel
                                  ? Padding(
                                      key: const ValueKey(
                                        'streaming-turn-thinking-label',
                                      ),
                                      padding: const EdgeInsetsDirectional.only(
                                        start: Spacing.xs,
                                      ),
                                      child: ThinkingStatusLabel(
                                        startedAt: widget.message.timestamp,
                                        animate: !_disableAnimations,
                                      ),
                                    )
                                  : const SizedBox.shrink(
                                      key: ValueKey(
                                        'streaming-turn-thinking-label-empty',
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
            )
          : const SizedBox.shrink(key: ValueKey('streaming-turn-footer-empty')),
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
