import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/native_chrome_visibility.dart';
import 'chat_voice_mode_controller.dart';
import 'voice_mode_error_text.dart';

class ChatVoiceModeOverlay extends ConsumerWidget {
  const ChatVoiceModeOverlay({super.key, required this.bottomOffset});

  final double bottomOffset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(
      chatVoiceModeControllerProvider.select((call) => call.noticeCount),
      (previous, next) {
        final notice = ref.read(chatVoiceModeControllerProvider).notice;
        if (next > (previous ?? 0) && notice != null) {
          final l10n = AppLocalizations.of(context)!;
          UiUtils.showMessage(context, voiceModeNoticeText(l10n, notice));
        }
      },
    );
    final snapshot = ref.watch(chatVoiceModeControllerProvider);
    if (!snapshot.isActive && snapshot.phase != ChatVoiceModePhase.error) {
      return const Positioned.fill(
        child: IgnorePointer(child: SizedBox.shrink()),
      );
    }

    final bottom = bottomOffset + Spacing.sm;
    if (PlatformUiCapabilities.usesNativeIOS26) {
      return Positioned(
        left: Spacing.inputPadding,
        right: Spacing.inputPadding,
        bottom: bottom,
        child: _VoiceIsland(snapshot: snapshot),
      );
    }
    return Positioned(
      left: Spacing.inputPadding,
      right: Spacing.inputPadding,
      bottom: bottom,
      child: AnimatedSize(
        key: const ValueKey('voice-mode-surface-size'),
        duration: context.motionDuration(const Duration(milliseconds: 180)),
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        child: AnimatedSwitcher(
          key: const ValueKey('voice-mode-surface-switcher'),
          duration: context.motionDuration(AnimationDuration.microInteraction),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              alignment: Alignment.bottomCenter,
              children: <Widget>[...previousChildren, ?currentChild],
            );
          },
          transitionBuilder: (child, animation) {
            if (context.reduceMotion) {
              return child;
            }
            final scale = Tween<double>(begin: 0.98, end: 1).animate(
              CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              ),
            );
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: scale,
                alignment: Alignment.bottomCenter,
                child: child,
              ),
            );
          },
          child: snapshot.isCollapsed
              ? _CollapsedVoicePill(
                  key: const ValueKey('voice-mode-collapsed'),
                  snapshot: snapshot,
                )
              : _ExpandedVoicePanel(
                  key: const ValueKey('voice-mode-expanded'),
                  snapshot: snapshot,
                ),
        ),
      ),
    );
  }
}

/// The call on iOS 26: one Liquid Glass island that morphs between the pill
/// and the panel. The panel leaves the transcript and the reply to the chat,
/// which shows both sides of the call.
///
/// The panel keeps room for its tallest content at the current text size, an
/// error included, rather than growing with the call as it does elsewhere:
/// the native view grows with the glass, and SwiftUI then draws the glass
/// out of place for a few frames. Its size changes only with the text size
/// or the width, and the island follows without being created again.
class _VoiceIsland extends StatelessWidget {
  const _VoiceIsland({required this.snapshot});

  final ChatVoiceModeSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = _VoiceIslandMetrics.of(context);
        final collapsedSize = Size(
          math.min(constraints.maxWidth, metrics.pillWidth),
          metrics.pillHeight,
        );
        final expandedSize = Size(
          constraints.maxWidth,
          metrics.panelHeight + AdaptiveFloatingIsland.expandedPadding.vertical,
        );
        final expanded = !snapshot.isCollapsed;
        return NativeChromeWhileRouteVisible(
          replacement: SizedBox.fromSize(
            size: expanded ? expandedSize : collapsedSize,
          ),
          child: AdaptiveFloatingIsland(
            key: const ValueKey('voice-mode-island'),
            isExpanded: expanded,
            collapsedSize: collapsedSize,
            expandedSize: expandedSize,
            collapsed: _CollapsedVoicePill(snapshot: snapshot, onGlass: true),
            expanded: _ExpandedVoicePanel(snapshot: snapshot, onGlass: true),
          ),
        );
      },
    );
  }
}

/// The voice island's sizes at the current text size and language.
@immutable
class _VoiceIslandMetrics {
  const _VoiceIslandMetrics({
    required this.pillWidth,
    required this.pillHeight,
    required this.panelHeight,
  });

  /// The pill's width, glass included: room for the longest status label.
  final double pillWidth;

  /// The pill's height.
  final double pillHeight;

  /// The panel's height inside its glass: room for the header, a two-line
  /// error and the controls.
  final double panelHeight;

  /// The metrics last measured, with what they were measured for. The
  /// overlay rebuilds with every change of the call, such as the voice's
  /// intensity, and the text size and language rarely change.
  static (Object, _VoiceIslandMetrics)? _last;

  static _VoiceIslandMetrics of(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final labelStyle = AppTypography.labelStyle.copyWith(
      fontWeight: FontWeight.w700,
    );
    final smallStyle = AppTypography.small;
    final key = (scaler, direction, l10n.localeName, labelStyle, smallStyle);
    if (_last case (final lastKey, final metrics) when lastKey == key) {
      return metrics;
    }

    TextPainter layOut(TextStyle style, String text, int lines) => TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: lines,
    )..layout();
    // Lines with an ascender, an accent and a descender.
    double linesHeight(TextStyle style, int lines) {
      final painter = layOut(style, List.filled(lines, 'Åg').join('\n'), lines);
      final height = painter.height;
      painter.dispose();
      return height;
    }

    double labelWidth = 0;
    for (final label in [
      l10n.voiceCallReady,
      l10n.voiceCallConnecting,
      l10n.voiceCallListening,
      l10n.voiceCallProcessing,
      l10n.voiceCallSpeaking,
      l10n.voiceCallPaused,
      l10n.voiceCallMuted,
      l10n.voiceCallDisconnected,
      l10n.error,
    ]) {
      final painter = layOut(labelStyle, label, 1);
      labelWidth = math.max(labelWidth, painter.width.ceilToDouble());
      painter.dispose();
    }
    labelWidth = math.min(labelWidth, _pillLabelMaxWidth);
    final labelLine = linesHeight(labelStyle, 1);
    final smallLine = linesHeight(smallStyle, 1);

    final pillHeight = math.max(
      _pillMinHeight,
      math.max(labelLine, TouchTarget.micro) + 2 * _pillVerticalPadding,
    );
    final pillWidth =
        AdaptiveFloatingIsland.collapsedPadding.horizontal +
        _StatusDot.compactExtent +
        Spacing.sm +
        labelWidth +
        Spacing.sm +
        TouchTarget.micro +
        Spacing.xxs +
        TouchTarget.micro;

    final header = [
      _StatusDot.envelopeExtent,
      labelLine + smallLine,
      TouchTarget.micro,
    ].reduce(math.max);
    final error = linesHeight(smallStyle, _errorMaxLines);
    final panelHeight =
        header + Spacing.sm + error + Spacing.md + TouchTarget.medium;

    final metrics = _VoiceIslandMetrics(
      pillWidth: pillWidth,
      pillHeight: pillHeight,
      panelHeight: panelHeight.ceilToDouble(),
    );
    _last = (key, metrics);
    return metrics;
  }
}

/// The widest the pill's status label gets.
const double _pillLabelMaxWidth = 220;

/// The pill's least height.
const double _pillMinHeight = 52;

/// The pill's room above and below its row.
const double _pillVerticalPadding = 10;

/// The lines an error may take in the panel.
const int _errorMaxLines = 2;

class _ExpandedVoicePanel extends ConsumerWidget {
  const _ExpandedVoicePanel({
    super.key,
    required this.snapshot,
    this.onGlass = false,
  });

  final ChatVoiceModeSnapshot snapshot;

  /// Whether the panel is the island's content, which keeps one height and
  /// shows no transcript or reply: room for an error sits under the header.
  final bool onGlass;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final controller = ref.read(chatVoiceModeControllerProvider.notifier);

    final header = Row(
      children: [
        _StatusDot(snapshot: snapshot),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _phaseLabel(l10n, snapshot),
                style: AppTypography.labelStyle.copyWith(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
                // The island's panel keeps room for one line.
                maxLines: onGlass ? 1 : null,
                overflow: onGlass ? TextOverflow.ellipsis : null,
              ),
              Text(
                _formatElapsed(snapshot.elapsed),
                style: AppTypography.small.copyWith(color: theme.textSecondary),
              ),
            ],
          ),
        ),
        _AdaptiveVoiceAction(
          tooltip: l10n.voiceCallMinimize,
          onPressed: controller.collapse,
          icon: Platform.isIOS
              ? CupertinoIcons.chevron_down
              : Icons.keyboard_arrow_down_rounded,
          compact: true,
        ),
      ],
    );
    final error = snapshot.errorMessage == null
        ? null
        : Text(
            voiceModeErrorText(
                  l10n,
                  kind: snapshot.errorKind,
                  message: snapshot.errorMessage,
                ) ??
                snapshot.errorMessage!,
            style: AppTypography.small.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
            maxLines: _errorMaxLines,
            overflow: TextOverflow.ellipsis,
          );
    final controls = Row(
      children: [
        // The three toggles draw native SF Symbols on iOS 26, which
        // animate each change of state.
        _CircleAction(
          tooltip: snapshot.isMuted ? l10n.unmute : l10n.mute,
          icon: snapshot.isMuted
              ? (Platform.isIOS
                    ? CupertinoIcons.mic_slash_fill
                    : Icons.mic_off_rounded)
              : (Platform.isIOS ? CupertinoIcons.mic_fill : Icons.mic_rounded),
          symbol: snapshot.isMuted ? 'mic.slash.fill' : 'mic.fill',
          symbolTransition: AdaptiveSymbolTransition.magic,
          onPressed: controller.toggleMute,
        ),
        const SizedBox(width: Spacing.sm),
        _CircleAction(
          tooltip: snapshot.isSpeakerphoneEnabled
              ? l10n.voiceCallSpeakerOff
              : l10n.voiceCallSpeakerOn,
          icon: snapshot.isSpeakerphoneEnabled
              ? (Platform.isIOS
                    ? CupertinoIcons.speaker_3_fill
                    : Icons.volume_up_rounded)
              : (Platform.isIOS
                    ? CupertinoIcons.speaker_1
                    : Icons.volume_down_rounded),
          symbol: snapshot.isSpeakerphoneEnabled
              ? 'speaker.wave.3.fill'
              : 'speaker.wave.1',
          symbolTransition: AdaptiveSymbolTransition.replace,
          // The waves play while the assistant's voice does.
          symbolEffect: snapshot.phase == ChatVoiceModePhase.speaking
              ? AdaptiveSymbolEffect.variableColor
              : null,
          onPressed: controller.toggleSpeakerphone,
        ),
        const SizedBox(width: Spacing.sm),
        _CircleAction(
          tooltip: snapshot.canResume
              ? l10n.voiceCallResume
              : l10n.voiceCallPause,
          icon: snapshot.canResume
              ? (Platform.isIOS
                    ? CupertinoIcons.play_fill
                    : Icons.play_arrow_rounded)
              : (Platform.isIOS
                    ? CupertinoIcons.pause_fill
                    : Icons.pause_rounded),
          symbol: snapshot.canResume ? 'play.fill' : 'pause.fill',
          symbolTransition: AdaptiveSymbolTransition.replace,
          onPressed: snapshot.canResume
              ? controller.resume
              : (snapshot.canPause ? controller.pause : null),
        ),
        const Spacer(),
        _CircleAction(
          tooltip: l10n.voiceCallEnd,
          destructive: true,
          icon: Platform.isIOS
              ? CupertinoIcons.phone_down_fill
              : Icons.call_end_rounded,
          onPressed: controller.stop,
        ),
      ],
    );

    if (onGlass) {
      return Column(
        key: const ValueKey('voice-overlay-expanded'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: Spacing.sm),
          // The chat already shows both sides of the call, so the island
          // keeps only room for an error under the header. An error taller
          // than measured, such as in a script with taller lines, is clipped
          // rather than pushing the controls.
          Expanded(
            child: ClipRect(
              child: OverflowBox(
                alignment: AlignmentDirectional.topStart,
                maxHeight: double.infinity,
                child: error ?? const SizedBox.shrink(),
              ),
            ),
          ),
          const SizedBox(height: Spacing.md),
          controls,
        ],
      );
    }

    return DecoratedBox(
      key: const ValueKey('voice-overlay-expanded'),
      decoration: BoxDecoration(
        color: theme.cardBackground.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.cardBorder),
        boxShadow: ConduitShadows.messageBubble(context),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            const SizedBox(height: Spacing.sm),
            _VoiceText(snapshot: snapshot),
            if (error != null) ...[const SizedBox(height: Spacing.xs), error],
            const SizedBox(height: Spacing.md),
            controls,
          ],
        ),
      ),
    );
  }
}

class _CollapsedVoicePill extends ConsumerWidget {
  const _CollapsedVoicePill({
    super.key,
    required this.snapshot,
    this.onGlass = false,
  });

  final ChatVoiceModeSnapshot snapshot;

  /// Whether the pill is the island's content, which has a fixed width: the
  /// status label then takes the room the island keeps for its longest one.
  final bool onGlass;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final controller = ref.read(chatVoiceModeControllerProvider.notifier);

    final label = Text(
      _phaseLabel(l10n, snapshot),
      style: AppTypography.labelStyle.copyWith(
        color: theme.textPrimary,
        fontWeight: FontWeight.w700,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final row = Row(
      mainAxisSize: onGlass ? MainAxisSize.max : MainAxisSize.min,
      children: [
        _StatusDot(snapshot: snapshot, compact: true),
        const SizedBox(width: Spacing.sm),
        if (onGlass)
          Expanded(child: label)
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _pillLabelMaxWidth),
            child: label,
          ),
        const SizedBox(width: Spacing.sm),
        _AdaptiveVoiceAction(
          tooltip: l10n.voiceCallExpand,
          onPressed: controller.expand,
          icon: Platform.isIOS
              ? CupertinoIcons.chevron_up
              : Icons.keyboard_arrow_up_rounded,
          compact: true,
        ),
        const SizedBox(width: Spacing.xxs),
        _AdaptiveVoiceAction(
          tooltip: l10n.voiceCallEnd,
          onPressed: controller.stop,
          icon: Platform.isIOS
              ? CupertinoIcons.phone_down_fill
              : Icons.call_end_rounded,
          destructive: true,
          compact: true,
        ),
      ],
    );

    if (onGlass) {
      return KeyedSubtree(
        key: const ValueKey('voice-overlay-collapsed'),
        child: row,
      );
    }

    return Align(
      key: const ValueKey('voice-overlay-collapsed'),
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _pillMinHeight),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.cardBackground.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: theme.cardBorder),
            boxShadow: ConduitShadows.messageBubble(context),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              _pillVerticalPadding,
              10,
              _pillVerticalPadding,
            ),
            child: row,
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.snapshot, this.compact = false});

  final ChatVoiceModeSnapshot snapshot;
  final bool compact;

  /// The compact dot's side, in the pill.
  static const double compactExtent = 10;

  /// The room the full dot keeps for its largest pulse, in the panel.
  static const double envelopeExtent = 22;

  @override
  Widget build(BuildContext context) {
    final color = switch (snapshot.phase) {
      ChatVoiceModePhase.listening => context.conduitTheme.success,
      ChatVoiceModePhase.speaking => context.conduitTheme.buttonPrimary,
      ChatVoiceModePhase.paused ||
      ChatVoiceModePhase.muted => context.conduitTheme.warning,
      ChatVoiceModePhase.error => Theme.of(context).colorScheme.error,
      _ => context.conduitTheme.textSecondary,
    };
    const baseSize = 14.0;
    const maxSize = envelopeExtent;
    final intensityScale =
        1.0 +
        (snapshot.intensity.clamp(0, 10).toDouble() / 10.0) *
            (maxSize / baseSize - 1.0);
    final coreSize = compact ? compactExtent : baseSize;
    final envelopeSize = compact ? coreSize : maxSize;

    return SizedBox.square(
      key: const ValueKey('voice-status-dot'),
      dimension: envelopeSize,
      child: Center(
        child: Transform.scale(
          key: const ValueKey('voice-status-dot-scale'),
          scale: compact || context.reduceMotion ? 1 : intensityScale,
          child: SizedBox.square(
            dimension: coreSize,
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}

class _VoiceText extends StatelessWidget {
  const _VoiceText({required this.snapshot});

  final ChatVoiceModeSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    if (snapshot.phase == ChatVoiceModePhase.speaking ||
        snapshot.phase == ChatVoiceModePhase.sending) {
      final spoken = snapshot.spokenResponse.trim();
      if (spoken.isEmpty) {
        return const SizedBox(height: 36);
      }
      return _KaraokeResponseBar(snapshot: snapshot);
    }

    final text = snapshot.transcript;
    if (text.trim().isEmpty) {
      return const SizedBox(height: 20);
    }

    return Text(
      text.trim(),
      style: AppTypography.bodyMediumStyle.copyWith(
        color: context.conduitTheme.textPrimary,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _KaraokeResponseBar extends StatelessWidget {
  const _KaraokeResponseBar({required this.snapshot});

  final ChatVoiceModeSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final rawText = snapshot.spokenResponse;
    final text = rawText.trim();
    final leadingTrim = rawText.length - rawText.trimLeft().length;
    final adjustedStart = snapshot.spokenWordStart == null
        ? null
        : snapshot.spokenWordStart! - leadingTrim;
    final adjustedEnd = snapshot.spokenWordEnd == null
        ? null
        : snapshot.spokenWordEnd! - leadingTrim;
    final baseStyle = AppTypography.bodyMediumStyle.copyWith(
      color: theme.textPrimary.withValues(alpha: Alpha.strong),
      fontWeight: FontWeight.w500,
      height: 1.25,
    );
    final highlightStyle = baseStyle.copyWith(
      color: theme.buttonPrimaryText,
      backgroundColor: theme.buttonPrimary,
      fontWeight: FontWeight.w800,
    );

    return Semantics(
      label: text,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surfaceContainerHighest.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.cardBorder.withValues(alpha: 0.75),
            width: BorderWidth.thin,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.xs,
          ),
          child: RichText(
            text: _karaokeTextSpan(
              text: text,
              baseStyle: baseStyle,
              highlightStyle: highlightStyle,
              start: adjustedStart,
              end: adjustedEnd,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textScaler: MediaQuery.textScalerOf(context),
          ),
        ),
      ),
    );
  }

  TextSpan _karaokeTextSpan({
    required String text,
    required TextStyle baseStyle,
    required TextStyle highlightStyle,
    required int? start,
    required int? end,
  }) {
    if (start == null ||
        end == null ||
        start < 0 ||
        end <= start ||
        start >= text.length) {
      return TextSpan(text: text, style: baseStyle);
    }

    final safeStart = start.clamp(0, text.length).toInt();
    final safeEnd = end.clamp(safeStart, text.length).toInt();
    return TextSpan(
      children: [
        if (safeStart > 0)
          TextSpan(text: text.substring(0, safeStart), style: baseStyle),
        TextSpan(
          text: text.substring(safeStart, safeEnd),
          style: highlightStyle,
        ),
        if (safeEnd < text.length)
          TextSpan(text: text.substring(safeEnd), style: baseStyle),
      ],
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.symbol,
    this.symbolEffect,
    this.symbolTransition,
    this.destructive = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final String? symbol;
  final AdaptiveSymbolEffect? symbolEffect;
  final AdaptiveSymbolTransition? symbolTransition;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return _AdaptiveVoiceAction(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: icon,
      symbol: symbol,
      symbolEffect: symbolEffect,
      symbolTransition: symbolTransition,
      destructive: destructive,
    );
  }
}

class _AdaptiveVoiceAction extends StatelessWidget {
  const _AdaptiveVoiceAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.symbol,
    this.symbolEffect,
    this.symbolTransition,
    this.destructive = false,
    this.compact = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  /// An SF Symbol for [icon], drawn natively on iOS 26 so that it can
  /// animate; null keeps [icon] everywhere.
  final String? symbol;
  final AdaptiveSymbolEffect? symbolEffect;
  final AdaptiveSymbolTransition? symbolTransition;
  final bool destructive;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();
    final size = compact ? TouchTarget.micro : TouchTarget.medium;
    final iconSize = compact ? IconSize.sm : IconSize.medium;
    final color = destructive ? Theme.of(context).colorScheme.error : null;
    final iconColor = onPressed == null
        ? theme.iconDisabled
        : destructive
        ? Theme.of(context).colorScheme.onError
        : theme.iconSecondary;

    return AdaptiveTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        child: AdaptiveButton.child(
          onPressed: onPressed,
          enabled: onPressed != null,
          style: usesOpaqueFallback
              ? AdaptiveButtonStyle.filled
              : destructive
              ? AdaptiveButtonStyle.filled
              : AdaptiveButtonStyle.glass,
          color: destructive
              ? Theme.of(context).colorScheme.error
              : usesOpaqueFallback
              ? theme.surfaceContainerHighest
              : color,
          size: compact ? AdaptiveButtonSize.small : AdaptiveButtonSize.medium,
          minSize: Size(size, size),
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(AppBorderRadius.circular),
          useSmoothRectangleBorder: false,
          child: switch (symbol) {
            final symbol? => AdaptiveSymbolIcon(
              symbol: symbol,
              fallbackIcon: icon,
              size: iconSize,
              color: iconColor,
              semanticLabel: tooltip,
              effect: symbolEffect,
              transition: symbolTransition,
            ),
            null => Icon(
              icon,
              size: iconSize,
              color: iconColor,
              semanticLabel: tooltip,
            ),
          },
        ),
      ),
    );
  }
}

String _phaseLabel(AppLocalizations l10n, ChatVoiceModeSnapshot snapshot) {
  if (snapshot.isMuted) {
    return l10n.voiceCallMuted;
  }
  return switch (snapshot.phase) {
    ChatVoiceModePhase.idle => l10n.voiceCallReady,
    ChatVoiceModePhase.starting => l10n.voiceCallConnecting,
    ChatVoiceModePhase.listening => l10n.voiceCallListening,
    ChatVoiceModePhase.sending => l10n.voiceCallProcessing,
    ChatVoiceModePhase.speaking => l10n.voiceCallSpeaking,
    ChatVoiceModePhase.paused => l10n.voiceCallPaused,
    ChatVoiceModePhase.muted => l10n.voiceCallMuted,
    ChatVoiceModePhase.ending => l10n.voiceCallDisconnected,
    ChatVoiceModePhase.ended => l10n.voiceCallDisconnected,
    ChatVoiceModePhase.error => l10n.error,
  };
}

String _formatElapsed(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}
