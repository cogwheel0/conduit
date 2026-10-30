import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../providers/text_to_speech_provider.dart';

/// Controls the active read-aloud request without covering the transcript.
class SpeechPlaybackBar extends ConsumerWidget {
  const SpeechPlaybackBar({super.key});

  String _timestamp(Duration elapsed) {
    final seconds = elapsed.inSeconds;
    final minutes = (seconds ~/ 60) % 60;
    final tail = (seconds % 60).toString().padLeft(2, '0');
    return seconds < 3600
        ? '${seconds ~/ 60}:$tail'
        : '${seconds ~/ 3600}:${minutes.toString().padLeft(2, '0')}:$tail';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(textToSpeechControllerProvider);
    if (playback.activeMessageId == null ||
        playback.status == TtsPlaybackStatus.idle) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final controller = ref.read(textToSpeechControllerProvider.notifier);
    final failed = playback.status == TtsPlaybackStatus.error;
    final paused = playback.status == TtsPlaybackStatus.paused;
    final index = playback.activeSentenceIndex;
    final sentences = playback.sentences;
    final wordProgress =
        index >= 0 && index < sentences.length && sentences[index].isNotEmpty
        ? (playback.wordEndInSentence ?? 0) / sentences[index].length
        : 0.0;
    final progress = playback.duration > Duration.zero
        ? (playback.elapsed.inMilliseconds / playback.duration.inMilliseconds)
              .clamp(0.0, 1.0)
        : sentences.isEmpty
        ? 0.0
        : ((index.clamp(0, sentences.length) + wordProgress) / sentences.length)
              .clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.inputPadding,
        0,
        Spacing.inputPadding,
        Spacing.sm,
      ),
      child: Container(
        key: const ValueKey('speech-playback-bar'),
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          color: theme.surfaceContainer,
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
              child: Icon(Icons.graphic_eq),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failed ? l10n.error : _timestamp(playback.elapsed),
                    key: const ValueKey('speech-playback-elapsed'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodySmall?.copyWith(
                      color: failed ? theme.error : theme.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Semantics(
                    label: l10n.ttsListen,
                    value: '${(progress * 100).round()}%',
                    child: AdaptiveProgressIndicator.linear(
                      value: playback.isBusy ? null : progress,
                      color: failed ? theme.error : theme.buttonPrimary,
                      minHeight: 2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            if (playback.canSeek && !failed && !playback.isBusy) ...[
              ConduitAdaptiveAppBarIconButton(
                key: const ValueKey('speech-playback-backward'),
                icon: Icons.fast_rewind_rounded,
                iosSymbol: 'gobackward.15',
                semanticLabel: l10n.ttsSkipBackward,
                onPressed: playback.seeking
                    ? null
                    : () => controller.skip(const Duration(seconds: -15)),
              ),
            ],
            if (failed)
              ConduitAdaptiveAppBarIconButton(
                key: const ValueKey('speech-playback-retry'),
                icon: Icons.refresh,
                iosSymbol: 'arrow.clockwise',
                semanticLabel: l10n.retry,
                onPressed: controller.retry,
              )
            else if (!playback.isBusy)
              ConduitAdaptiveAppBarIconButton(
                key: const ValueKey('speech-playback-toggle'),
                icon: paused ? Icons.play_arrow : Icons.pause,
                iosSymbol: paused ? 'play.fill' : 'pause.fill',
                semanticLabel: paused
                    ? l10n.voiceCallResume
                    : l10n.voiceCallPause,
                onPressed: paused ? controller.resume : controller.pause,
              ),
            if (playback.canSeek && !failed && !playback.isBusy)
              ConduitAdaptiveAppBarIconButton(
                key: const ValueKey('speech-playback-forward'),
                icon: Icons.fast_forward_rounded,
                iosSymbol: 'goforward.15',
                semanticLabel: l10n.ttsSkipForward,
                onPressed: playback.seeking
                    ? null
                    : () => controller.skip(const Duration(seconds: 15)),
              ),
            ConduitAdaptiveAppBarIconButton(
              key: const ValueKey('speech-playback-stop'),
              icon: Icons.close,
              iosSymbol: 'xmark',
              semanticLabel: l10n.ttsStop,
              onPressed: controller.stop,
            ),
          ],
        ),
      ),
    );
  }
}
