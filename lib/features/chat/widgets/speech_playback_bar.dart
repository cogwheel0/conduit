import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../providers/text_to_speech_provider.dart';

/// Width of the island's compact progress track, or of its error label.
const double _compactTrackWidth = 96;

/// Height of the progress track: the native `UIProgressView`'s, which is the
/// taller one.
const double _trackHeight = 4;

/// Extent of the leading waveform glyph.
const double _glyphExtent = 20;

/// Controls the active read-aloud request without covering the transcript.
///
/// On iOS 26 and later it is a Liquid Glass island above the composer: a
/// compact pill with the progress and the main action that expands to every
/// control. Elsewhere it is a bar with every control.
class SpeechPlaybackBar extends ConsumerStatefulWidget {
  const SpeechPlaybackBar({super.key});

  @override
  ConsumerState<SpeechPlaybackBar> createState() => _SpeechPlaybackBarState();
}

class _SpeechPlaybackBarState extends ConsumerState<SpeechPlaybackBar> {
  /// The message whose playback the island shows in full. Each reading
  /// starts compact.
  String? _expandedMessageId;

  /// The height of the time over the progress track, for the text style and
  /// scale it was measured with.
  (TextStyle?, TextScaler, double)? _infoHeight;

  String _timestamp(Duration elapsed) {
    final seconds = elapsed.inSeconds;
    final minutes = (seconds ~/ 60) % 60;
    final tail = (seconds % 60).toString().padLeft(2, '0');
    return seconds < 3600
        ? '${seconds ~/ 60}:$tail'
        : '${seconds ~/ 3600}:${minutes.toString().padLeft(2, '0')}:$tail';
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(textToSpeechControllerProvider);
    final messageId = playback.activeMessageId;
    if (messageId == null || playback.status == TtsPlaybackStatus.idle) {
      // Read by the next reading's build only, so it needs no rebuild.
      _expandedMessageId = null;
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final controller = ref.read(textToSpeechControllerProvider.notifier);
    final failed = playback.status == TtsPlaybackStatus.error;
    final paused = playback.status == TtsPlaybackStatus.paused;
    final canSeek = playback.canSeek && !failed && !playback.isBusy;
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

    final elapsedStyle = theme.bodySmall?.copyWith(
      color: failed ? theme.error : theme.textPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final elapsed = Text(
      failed ? l10n.error : _timestamp(playback.elapsed),
      key: const ValueKey('speech-playback-elapsed'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: elapsedStyle,
    );
    final track = Semantics(
      label: l10n.ttsListen,
      value: '${(progress * 100).round()}%',
      child: AdaptiveProgressIndicator.linear(
        value: playback.isBusy ? null : progress,
        color: failed ? theme.error : theme.buttonPrimary,
        minHeight: 2,
      ),
    );

    final backward = _PlaybackAction(
      key: const ValueKey('speech-playback-backward'),
      icon: Icons.fast_rewind_rounded,
      symbol: 'gobackward.15',
      label: l10n.ttsSkipBackward,
      onPressed: playback.seeking
          ? null
          : () => controller.skip(const Duration(seconds: -15)),
    );
    final retry = _PlaybackAction(
      key: const ValueKey('speech-playback-retry'),
      icon: Icons.refresh,
      symbol: 'arrow.clockwise',
      label: l10n.retry,
      onPressed: controller.retry,
    );
    final toggle = _PlaybackAction(
      key: const ValueKey('speech-playback-toggle'),
      icon: paused ? Icons.play_arrow : Icons.pause,
      symbol: paused ? 'play.fill' : 'pause.fill',
      label: paused ? l10n.voiceCallResume : l10n.voiceCallPause,
      onPressed: paused ? controller.resume : controller.pause,
    );
    final forward = _PlaybackAction(
      key: const ValueKey('speech-playback-forward'),
      icon: Icons.fast_forward_rounded,
      symbol: 'goforward.15',
      label: l10n.ttsSkipForward,
      onPressed: playback.seeking
          ? null
          : () => controller.skip(const Duration(seconds: 15)),
    );
    final stop = _PlaybackAction(
      key: const ValueKey('speech-playback-stop'),
      icon: Icons.close,
      symbol: 'xmark',
      label: l10n.ttsStop,
      onPressed: controller.stop,
    );
    final actions = [
      if (canSeek) backward,
      if (failed) retry else if (!playback.isBusy) toggle,
      if (canSeek) forward,
      stop,
    ];

    if (!PlatformUiCapabilities.usesNativeIOS26) {
      return _bar(
        theme: theme,
        elapsed: elapsed,
        track: track,
        actions: actions,
      );
    }

    final expanded = _expandedMessageId == messageId;
    void setExpanded(bool value) =>
        setState(() => _expandedMessageId = value ? messageId : null);
    // The compact pill keeps the one action the moment calls for.
    final compactAction = failed
        ? retry
        : playback.isBusy
        ? stop
        : toggle;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.inputPadding,
        0,
        Spacing.inputPadding,
        Spacing.sm,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final controlExtent = conduitScaledControlExtent(context);
          final contentHeight = math.max(
            controlExtent,
            _measureInfoHeight(context, elapsedStyle),
          );
          final collapsedSize = Size(
            math.min(
              constraints.maxWidth,
              AdaptiveFloatingIsland.collapsedPadding.horizontal +
                  _glyphExtent +
                  Spacing.sm +
                  _compactTrackWidth +
                  Spacing.sm +
                  controlExtent,
            ),
            contentHeight,
          );
          final expandedSize = Size(
            constraints.maxWidth,
            contentHeight + AdaptiveFloatingIsland.expandedPadding.vertical,
          );
          final glyph = AdaptiveSymbolIcon(
            symbol: 'waveform',
            fallbackIcon: Icons.graphic_eq,
            size: _glyphExtent,
            color: failed ? theme.error : theme.textPrimary,
            effect: playback.status == TtsPlaybackStatus.speaking
                ? AdaptiveSymbolEffect.variableColor
                : null,
          );

          final island = AdaptiveFloatingIsland(
            key: const ValueKey('speech-playback-bar'),
            isExpanded: expanded,
            collapsedSize: collapsedSize,
            expandedSize: expandedSize,
            onTap: expanded ? null : () => setExpanded(true),
            collapsed: Row(
              children: [
                Expanded(
                  child: _IslandToggle(
                    key: const ValueKey('speech-playback-expand'),
                    label: l10n.voiceCallExpand,
                    onTap: () => setExpanded(true),
                    child: Row(
                      children: [
                        glyph,
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: failed
                              ? elapsed
                              : SizedBox(
                                  height: _trackHeight,
                                  child: Center(child: track),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                _IslandButton(action: compactAction, extent: controlExtent),
              ],
            ),
            expanded: Row(
              children: [
                Expanded(
                  child: _IslandToggle(
                    key: const ValueKey('speech-playback-collapse'),
                    label: l10n.voiceCallMinimize,
                    onTap: () => setExpanded(false),
                    child: LayoutBuilder(
                      builder: (context, constraints) => Row(
                        children: [
                          // Narrow panels, such as at large text sizes,
                          // keep their room for the time.
                          if (constraints.maxWidth >= _compactTrackWidth) ...[
                            glyph,
                            const SizedBox(width: Spacing.sm),
                          ],
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                elapsed,
                                const SizedBox(height: Spacing.xs),
                                SizedBox(
                                  height: _trackHeight,
                                  child: Center(child: track),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                for (final action in actions)
                  _IslandButton(action: action, extent: controlExtent),
              ],
            ),
          );

          // Like the composer's native chrome, the glass leaves while a
          // sheet or another route covers it, so that UIKit cannot draw it
          // above them; its room stays so that the composer does not move.
          return ListenableBuilder(
            listenable: ThemedSheets.activeSheetListenable,
            builder: (context, _) {
              final visible =
                  !ThemedSheets.isCoveredBySheet(context) &&
                  TickerMode.valuesOf(context).enabled &&
                  (ModalRoute.isCurrentOf(context) ?? true);
              if (visible) return island;
              return SizedBox(
                height: expanded ? expandedSize.height : collapsedSize.height,
              );
            },
          );
        },
      ),
    );
  }

  /// The height of the time over the progress track.
  double _measureInfoHeight(BuildContext context, TextStyle? style) {
    final scaler = MediaQuery.textScalerOf(context);
    final cached = _infoHeight;
    if (cached != null && cached.$1 == style && cached.$2 == scaler) {
      return cached.$3;
    }
    final painter = TextPainter(
      text: TextSpan(text: '0:00', style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final height = painter.height + Spacing.xs + _trackHeight;
    painter.dispose();
    _infoHeight = (style, scaler, height);
    return height;
  }

  Widget _bar({
    required ConduitThemeExtension theme,
    required Widget elapsed,
    required Widget track,
    required List<_PlaybackAction> actions,
  }) {
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
                  elapsed,
                  const SizedBox(height: Spacing.xs),
                  track,
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            for (final action in actions)
              ConduitAdaptiveAppBarIconButton(
                key: action.key,
                icon: action.icon,
                iosSymbol: action.symbol,
                semanticLabel: action.label,
                onPressed: action.onPressed,
              ),
          ],
        ),
      ),
    );
  }
}

/// A playback control, drawn as a glass toolbar button in the bar and as a
/// plain symbol on the island's glass.
class _PlaybackAction {
  const _PlaybackAction({
    required this.key,
    required this.icon,
    required this.symbol,
    required this.label,
    required this.onPressed,
  });

  final Key key;
  final IconData icon;
  final String symbol;
  final String label;
  final VoidCallback? onPressed;
}

/// A control on the island. The island is the glass, so the control is a
/// plain native symbol rather than a glass button of its own.
class _IslandButton extends StatelessWidget {
  const _IslandButton({required this.action, required this.extent});

  final _PlaybackAction action;
  final double extent;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final enabled = action.onPressed != null;
    return AdaptiveButton.sfSymbol(
      key: action.key,
      onPressed: action.onPressed,
      enabled: enabled,
      sfSymbol: SFSymbol(
        action.symbol,
        size: kConduitNativeSingleActionSymbolExtent,
        color: enabled ? theme.textPrimary : theme.iconDisabled,
      ),
      style: AdaptiveButtonStyle.plain,
      minSize: Size.square(extent),
      padding: EdgeInsets.zero,
      semanticLabel: action.label,
      useSmoothRectangleBorder: false,
    );
  }
}

/// The island's progress area, which expands or collapses it.
class _IslandToggle extends StatelessWidget {
  const _IslandToggle({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: label,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onTap,
        // The native progress view would otherwise join the gesture arena,
        // win its sweep and cancel the tap.
        child: AbsorbPointer(child: child),
      ),
    );
  }
}
