import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

/// "Thinking…" while a reply has not produced anything yet, with the time
/// waited so far once it passes a second.
///
/// A soft highlight sweeps across the label in a few discrete steps and then
/// rests, so the wait reads as alive without asking for display-rate frames.
/// The sweep pauses while the app is in the background or the route is
/// hidden, and Reduce Motion leaves the label still. The elapsed time ticks
/// once a second in tabular figures so its width never jitters.
class ThinkingStatusLabel extends StatefulWidget {
  const ThinkingStatusLabel({
    super.key,
    required this.startedAt,
    this.animate = true,
    this.style,
  });

  /// When the reply was requested; the elapsed time counts from here.
  final DateTime startedAt;

  /// Whether the highlight sweeps. False leaves the label still (Reduce
  /// Motion); the elapsed time keeps counting either way.
  final bool animate;

  /// Overrides the label's text style. Defaults to the reasoning header's
  /// style, so the label hands over to a streamed "Thinking…" block without a
  /// visible change of type.
  final TextStyle? style;

  /// Elapsed time stays hidden below this, so a fast reply never flashes a
  /// counter that only reads "0s".
  static const Duration elapsedDelay = Duration(seconds: 1);

  /// The sweep: [sweepSteps] discrete positions over [sweepDuration], then a
  /// rest of [restDuration] before the next pass.
  static const int sweepSteps = 12;
  static const Duration sweepDuration = Duration(milliseconds: 1350);
  static const Duration restDuration = Duration(milliseconds: 1450);

  @override
  State<ThinkingStatusLabel> createState() => _ThinkingStatusLabelState();
}

class _ThinkingStatusLabelState extends State<ThinkingStatusLabel>
    with WidgetsBindingObserver {
  Timer? _sweepTimer;
  Timer? _clockTimer;

  /// -1 while resting; 0..[ThinkingStatusLabel.sweepSteps] - 1 mid-sweep.
  final ValueNotifier<int> _sweepStep = ValueNotifier<int>(-1);
  final ValueNotifier<int> _elapsedSeconds = ValueNotifier<int>(0);

  bool _tickerModeEnabled = true;
  bool _appForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appForeground = _isForeground(WidgetsBinding.instance.lifecycleState);
    _updateElapsed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncTimers();
  }

  @override
  void didUpdateWidget(covariant ThinkingStatusLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startedAt != widget.startedAt) _updateElapsed();
    if (oldWidget.animate != widget.animate) _syncTimers();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = _isForeground(state);
    if (foreground == _appForeground) return;
    _appForeground = foreground;
    if (foreground) _updateElapsed();
    _syncTimers();
  }

  bool _isForeground(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  bool get _running => _tickerModeEnabled && _appForeground;

  void _syncTimers() {
    if (!_running) {
      _clockTimer?.cancel();
      _clockTimer = null;
      _stopSweep();
      return;
    }
    _clockTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateElapsed(),
    );
    if (widget.animate) {
      if (_sweepTimer == null) _scheduleSweep(ThinkingStatusLabel.restDuration);
    } else {
      _stopSweep();
    }
  }

  void _stopSweep() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _sweepStep.value = -1;
  }

  void _scheduleSweep(Duration delay) {
    _sweepTimer = Timer(delay, _runSweep);
  }

  void _runSweep() {
    if (!mounted || !_running || !widget.animate) return;
    final interval = Duration(
      microseconds:
          ThinkingStatusLabel.sweepDuration.inMicroseconds ~/
          ThinkingStatusLabel.sweepSteps,
    );
    _sweepStep.value = 0;
    _sweepTimer = Timer.periodic(interval, (timer) {
      if (!mounted) return;
      final next = _sweepStep.value + 1;
      if (next >= ThinkingStatusLabel.sweepSteps) {
        timer.cancel();
        _sweepStep.value = -1;
        _scheduleSweep(ThinkingStatusLabel.restDuration);
        return;
      }
      _sweepStep.value = next;
    });
  }

  void _updateElapsed() {
    final elapsed = DateTime.now().difference(widget.startedAt);
    _elapsedSeconds.value = elapsed.isNegative ? 0 : elapsed.inSeconds;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sweepTimer?.cancel();
    _clockTimer?.cancel();
    _sweepStep.dispose();
    _elapsedSeconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Hosts without the app's delegates (isolated previews) read English.
    final l10n =
        AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('en'));
    final theme = context.conduitTheme;
    final textTheme = Theme.of(context).textTheme;
    final baseStyle =
        widget.style ?? textTheme.bodyLarge ?? AppTypography.chatMessageStyle;
    // Secondary text: quiet beside the reply but readable (4.5:1 or
    // better), the time in the same tone so "Thinking… 3s" reads as one
    // status. The sweep briefly lifts the label to primary.
    final restColor = theme.textSecondary;
    final labelStyle = baseStyle.copyWith(color: restColor);
    final elapsedStyle = baseStyle.copyWith(
      color: theme.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    // Both runs, the hidden empty time included, keep the style's own line
    // box, so the label is exactly one line of [baseStyle] tall and can stand
    // in a reply's first line without shifting it.
    final strut = StrutStyle.fromTextStyle(baseStyle, forceStrutHeight: true);
    final label = Text(
      l10n.thinking,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: labelStyle,
      strutStyle: strut,
    );

    return Semantics(
      container: true,
      label: l10n.thinking,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: RepaintBoundary(
                child: ValueListenableBuilder<int>(
                  valueListenable: _sweepStep,
                  child: label,
                  builder: (context, step, child) {
                    if (step < 0) return child!;
                    return ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (bounds) => _sweepShader(
                        bounds,
                        step: step,
                        rest: restColor,
                        highlight: theme.textPrimary,
                      ),
                      child: child,
                    );
                  },
                ),
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: _elapsedSeconds,
              builder: (context, seconds, _) {
                final show =
                    seconds >= ThinkingStatusLabel.elapsedDelay.inSeconds;
                return AnimatedOpacity(
                  opacity: show ? 1 : 0,
                  duration: context.motionDuration(
                    const Duration(milliseconds: 200),
                  ),
                  curve: Curves.easeOut,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 6),
                    child: Text(
                      show ? formatThinkingElapsed(l10n, seconds) : '',
                      maxLines: 1,
                      style: elapsedStyle,
                      strutStyle: strut,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Shader _sweepShader(
    Rect bounds, {
    required int step,
    required Color rest,
    required Color highlight,
  }) {
    // The band starts just off the leading edge and leaves past the trailing
    // edge, so the first and last steps only graze the label.
    const bandWidth = 0.42;
    final progress = (step + 1) / (ThinkingStatusLabel.sweepSteps + 1);
    final center = -bandWidth + progress * (1 + 2 * bandWidth);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final position = rtl ? 1 - center : center;
    double clampStop(double value) => value.clamp(0.0, 1.0);
    return LinearGradient(
      colors: [rest, rest, highlight, rest, rest],
      stops: [
        0,
        clampStop(position - bandWidth / 2),
        clampStop(position),
        clampStop(position + bandWidth / 2),
        1,
      ],
    ).createShader(bounds);
  }
}

/// "4s", or "1m 05s" from a minute on.
@visibleForTesting
String formatThinkingElapsed(AppLocalizations l10n, int seconds) {
  if (seconds < 60) return l10n.thinkingElapsedSeconds(seconds);
  final minutes = seconds ~/ 60;
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return l10n.thinkingElapsedMinutes(minutes, remainder);
}
