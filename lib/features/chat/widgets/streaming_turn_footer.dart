import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/services/platform_service.dart';
import '../../../core/services/settings_service.dart';
import '../providers/queued_completion_provider.dart';
import '../views/chat_turn_render_state.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/markdown/renderer/markdown_style.dart';
import 'five_rotating_dots.dart';

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
      _didTriggerRunningHaptic = false;
      return;
    }
    if (_didTriggerRunningHaptic) {
      return;
    }
    _didTriggerRunningHaptic = true;
    _streamingHaptic();
  }

  void _streamingHaptic() {
    final enabled =
        ref.read(streamingHapticsEnabledProvider) &&
        !widget.suppressStreamingHaptics;
    PlatformService.hapticFeedbackWithSettings(
      type: HapticType.light,
      hapticEnabled: enabled,
    );
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
                      top: ConduitMarkdownStyle.fromTheme(
                        context,
                      ).paragraphSpacing,
                      bottom: Spacing.xs,
                    ),
                    child: RepaintBoundary(
                      child: FiveRotatingDots(
                        size: 28,
                        color: context.conduitTheme.textSecondary.withValues(
                          alpha: 0.75,
                        ),
                        animate: !_disableAnimations,
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
