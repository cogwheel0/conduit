import 'dart:async';
import 'dart:math' as math;

import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/native_chrome_visibility.dart';
import '../providers/text_to_speech_provider.dart';

/// Room the compact island keeps for its progress, or for its error label.
const double _compactTrackWidth = 88;

/// The least room the compact island's progress may keep. A pill too narrow
/// for it beside the 15-second skips keeps only the main action.
const double _compactTrackMinWidth = 48;

/// Height of the progress track: the native `UIProgressView`'s, which is the
/// taller one.
const double _trackHeight = 4;

/// Height of the bar's scrubber, which needs room for a finger.
const double _barScrubberHeight = 28;

/// Extent of the leading waveform glyph.
const double _glyphExtent = 20;

/// The most controls the expanded island's row shows: back, play/pause,
/// forward and stop.
const int _maxPanelActions = 4;

/// How long a change made without a touch, such as VoiceOver adjusting the
/// scrubber, rests before the reading seeks there. A drag or a tap seeks
/// when the finger lifts.
const Duration _scrubCommitDelay = Duration(milliseconds: 200);

/// Controls the active read-aloud request without covering the transcript.
///
/// On iOS 26 and later it is a Liquid Glass island above the composer: a
/// compact pill with the progress and the main actions that expands to every
/// control. Elsewhere it is a bar with every control. Seekable readings scrub
/// by dragging or tapping their progress.
class SpeechPlaybackBar extends ConsumerStatefulWidget {
  const SpeechPlaybackBar({super.key});

  @override
  ConsumerState<SpeechPlaybackBar> createState() => _SpeechPlaybackBarState();
}

class _SpeechPlaybackBarState extends ConsumerState<SpeechPlaybackBar> {
  /// The message whose playback the island shows in full. Each reading
  /// starts compact.
  String? _expandedMessageId;

  /// The height of a line of the time, for the text style and scale it was
  /// measured with.
  (TextStyle?, TextScaler, double)? _lineHeight;

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
    // Scrubbing needs the reading's length to turn a point into a time.
    final scrubbable = canSeek && playback.duration > Duration.zero;
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
    final trackColor = failed ? theme.error : theme.buttonPrimary;
    final Widget track = scrubbable
        ? _ReadAloudScrubber(
            key: const ValueKey('speech-playback-scrubber'),
            progress: progress,
            duration: playback.duration,
            color: trackColor,
            label: l10n.ttsListen,
            onSeek: controller.seekTo,
          )
        : SizedBox(
            height: _trackHeight,
            child: Center(
              child: Semantics(
                label: l10n.ttsListen,
                value: '${(progress * 100).round()}%',
                child: AdaptiveProgressIndicator.linear(
                  value: playback.isBusy ? null : progress,
                  color: trackColor,
                  minHeight: 2,
                ),
              ),
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
    final speed = ref.watch(appSettingsProvider.select((s) => s.ttsSpeed));
    // The setting changes the reading under way, cloud and device voices
    // alike, and is the one Voice settings shows.
    Widget speedMenu({required double height, Color? tint}) => Semantics(
      label: l10n.ttsPlaybackSpeed,
      child: AdaptivePopupMenuButton.text<double>(
        key: const ValueKey('speech-playback-speed'),
        label: l10n.ttsSpeedValue(speed),
        items: [
          for (final preset in ttsSpeedPresets)
            AdaptivePopupMenuItem<double>(
              label: l10n.ttsSpeedValue(preset),
              value: preset,
              checked: preset == nearestTtsSpeed(speed),
            ),
        ],
        onSelected: (_, entry) => ref
            .read(appSettingsProvider.notifier)
            .setTtsSpeed(entry.value ?? speed),
        tint: tint,
        height: height,
        shrinkWrap: true,
      ),
    );

    if (!PlatformUiCapabilities.usesNativeIOS26) {
      return _bar(
        theme: theme,
        elapsed: elapsed,
        track: scrubbable
            ? SizedBox(height: _barScrubberHeight, child: track)
            : track,
        // The bar's row is tight at large text, so its speed shrinks to fit
        // rather than wrapping or overflowing.
        speed: Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: speedMenu(height: conduitScaledControlExtent(context)),
          ),
        ),
        actions: actions,
      );
    }

    final expanded = _expandedMessageId == messageId;
    void setExpanded(bool value) =>
        setState(() => _expandedMessageId = value ? messageId : null);
    // The compact pill keeps the action the moment calls for.
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
          final rowHeight = math.max(
            controlExtent,
            _measureLineHeight(context, elapsedStyle),
          );

          // The pill keeps its width through the reading: room for the
          // 15-second skips whenever they fit, and the progress takes what
          // the actions shown leave.
          final pillChrome =
              AdaptiveFloatingIsland.collapsedPadding.horizontal +
              controlExtent +
              2 * Spacing.sm;
          final pillWithSkips = math.min(
            constraints.maxWidth,
            pillChrome + _compactTrackWidth + 3 * controlExtent,
          );
          final compactSkips =
              pillWithSkips - pillChrome - 3 * controlExtent >=
              _compactTrackMinWidth;
          final collapsedSize = Size(
            compactSkips
                ? pillWithSkips
                : math.min(
                    constraints.maxWidth,
                    pillChrome + _compactTrackWidth + controlExtent,
                  ),
            rowHeight,
          );

          // The panel: the time, the progress and the speed on one row,
          // every other control on the next.
          final panelWidth = AdaptiveFloatingIsland.expandedPadding
              .deflateSize(Size(constraints.maxWidth, 0))
              .width;
          final panelControlExtent = math.min(
            controlExtent,
            panelWidth / _maxPanelActions,
          );
          final expandedSize = Size(
            constraints.maxWidth,
            rowHeight +
                Spacing.sm +
                panelControlExtent +
                AdaptiveFloatingIsland.expandedPadding.vertical,
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
                _IslandToggle(
                  key: const ValueKey('speech-playback-expand'),
                  label: l10n.voiceCallExpand,
                  onTap: () => setExpanded(true),
                  child: SizedBox.square(
                    dimension: controlExtent,
                    child: Center(child: glyph),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(child: failed ? elapsed : track),
                const SizedBox(width: Spacing.sm),
                if (compactSkips && canSeek)
                  _IslandButton(action: backward, extent: controlExtent),
                _IslandButton(action: compactAction, extent: controlExtent),
                if (compactSkips && canSeek)
                  _IslandButton(action: forward, extent: controlExtent),
              ],
            ),
            expanded: Column(
              children: [
                SizedBox(
                  height: rowHeight,
                  child: Row(
                    children: [
                      _IslandToggle(
                        key: const ValueKey('speech-playback-collapse'),
                        label: l10n.voiceCallMinimize,
                        onTap: () => setExpanded(false),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: controlExtent,
                            minHeight: rowHeight,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              glyph,
                              const SizedBox(width: Spacing.sm),
                              elapsed,
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(child: track),
                      // The speed reads with the time, at its own width,
                      // and leaves the next row to the controls.
                      const SizedBox(width: Spacing.sm),
                      speedMenu(height: rowHeight, tint: theme.textPrimary),
                    ],
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final action in actions)
                      _IslandButton(action: action, extent: panelControlExtent),
                  ],
                ),
              ],
            ),
          );

          // Like the composer's native chrome, the glass leaves while a
          // sheet or another route covers it, so that UIKit cannot draw it
          // above them; its room stays so that the composer does not move.
          return NativeChromeWhileRouteVisible(
            replacement: SizedBox(
              height: expanded ? expandedSize.height : collapsedSize.height,
            ),
            child: island,
          );
        },
      ),
    );
  }

  /// The height of a line of the time.
  double _measureLineHeight(BuildContext context, TextStyle? style) {
    final scaler = MediaQuery.textScalerOf(context);
    final cached = _lineHeight;
    if (cached != null && cached.$1 == style && cached.$2 == scaler) {
      return cached.$3;
    }
    final painter = TextPainter(
      text: TextSpan(text: '0:00', style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    _lineHeight = (style, scaler, height);
    return height;
  }

  Widget _bar({
    required ConduitThemeExtension theme,
    required Widget elapsed,
    required Widget track,
    required Widget speed,
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
            speed,
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

/// The reading's progress as a scrubber: dragging along it or tapping a
/// point on it moves the reading there.
///
/// The reader's position is held while they scrub and until the seek lands,
/// so playback updates neither fight their finger nor jump back.
class _ReadAloudScrubber extends StatefulWidget {
  const _ReadAloudScrubber({
    super.key,
    required this.progress,
    required this.duration,
    required this.color,
    required this.label,
    required this.onSeek,
  });

  final double progress;
  final Duration duration;
  final Color color;
  final String label;
  final Future<void> Function(Duration position) onSeek;

  @override
  State<_ReadAloudScrubber> createState() => _ReadAloudScrubberState();
}

class _ReadAloudScrubberState extends State<_ReadAloudScrubber> {
  /// Where the reader's finger, or the seek it asked for, holds the reading.
  double? _held;

  /// Whether a finger is on the slider: its change is seeked once it lifts.
  bool _touching = false;

  /// Seeks after a change made without a touch.
  Timer? _commit;

  void _onChanged(double value) {
    setState(() => _held = value);
    _commit?.cancel();
    if (!_touching) {
      _commit = Timer(_scrubCommitDelay, () => unawaited(_seek(value)));
    }
  }

  Future<void> _seek(double value) async {
    _commit?.cancel();
    setState(() => _held = value);
    await widget.onSeek(widget.duration * value);
    if (mounted && _held == value) setState(() => _held = null);
  }

  @override
  void dispose() {
    _commit?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _held ?? widget.progress;
    return AdaptiveSlider(
      value: value,
      onChangeStart: (_) => _touching = true,
      onChanged: _onChanged,
      onChangeEnd: (released) {
        _touching = false;
        unawaited(_seek(released));
      },
      seekOnTap: true,
      thumbless: true,
      activeColor: widget.color,
      semanticLabel: widget.label,
      semanticValue: '${(value * 100).round()}%',
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
