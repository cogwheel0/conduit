import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import 'chat_voice_mode_controller.dart';

class ChatVoiceModeOverlay extends ConsumerWidget {
  const ChatVoiceModeOverlay({super.key, required this.bottomOffset});

  final double bottomOffset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(chatVoiceModeControllerProvider);
    if (!snapshot.isActive && snapshot.phase != ChatVoiceModePhase.error) {
      return const Positioned.fill(
        child: IgnorePointer(child: SizedBox.shrink()),
      );
    }

    final bottom = bottomOffset + Spacing.sm;
    return Positioned(
      left: Spacing.inputPadding,
      right: Spacing.inputPadding,
      bottom: bottom,
      child: AnimatedSwitcher(
        duration: AnimationDuration.microInteraction,
        switchInCurve: AnimationCurves.microInteraction,
        switchOutCurve: AnimationCurves.microInteraction,
        child: snapshot.isCollapsed
            ? _CollapsedVoicePill(snapshot: snapshot)
            : _ExpandedVoicePanel(snapshot: snapshot),
      ),
    );
  }
}

class _ExpandedVoicePanel extends ConsumerWidget {
  const _ExpandedVoicePanel({required this.snapshot});

  final ChatVoiceModeSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final controller = ref.read(chatVoiceModeControllerProvider.notifier);

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
            Row(
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
                      ),
                      Text(
                        _formatElapsed(snapshot.elapsed),
                        style: AppTypography.small.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                _AdaptiveVoiceAction(
                  tooltip: 'Minimize',
                  onPressed: controller.collapse,
                  icon: Platform.isIOS
                      ? CupertinoIcons.chevron_down
                      : Icons.keyboard_arrow_down_rounded,
                  compact: true,
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            _VoiceText(snapshot: snapshot),
            if (snapshot.errorMessage != null) ...[
              const SizedBox(height: Spacing.xs),
              Text(
                snapshot.errorMessage!,
                style: AppTypography.small.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: Spacing.md),
            Row(
              children: [
                _CircleAction(
                  tooltip: snapshot.isMuted ? l10n.unmute : l10n.mute,
                  icon: snapshot.isMuted
                      ? (Platform.isIOS
                            ? CupertinoIcons.mic_slash_fill
                            : Icons.mic_off_rounded)
                      : (Platform.isIOS
                            ? CupertinoIcons.mic_fill
                            : Icons.mic_rounded),
                  onPressed: controller.toggleMute,
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
            ),
          ],
        ),
      ),
    );
  }
}

class _CollapsedVoicePill extends ConsumerWidget {
  const _CollapsedVoicePill({required this.snapshot});

  final ChatVoiceModeSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final controller = ref.read(chatVoiceModeControllerProvider.notifier);

    return Align(
      key: const ValueKey('voice-overlay-collapsed'),
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.cardBackground.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: theme.cardBorder),
            boxShadow: ConduitShadows.messageBubble(context),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusDot(snapshot: snapshot, compact: true),
                const SizedBox(width: Spacing.sm),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    _phaseLabel(l10n, snapshot),
                    style: AppTypography.labelStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                _AdaptiveVoiceAction(
                  tooltip: 'Expand',
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
            ),
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

  @override
  Widget build(BuildContext context) {
    final color = switch (snapshot.phase) {
      ChatVoiceModePhase.listening => Colors.green,
      ChatVoiceModePhase.speaking => context.conduitTheme.buttonPrimary,
      ChatVoiceModePhase.paused || ChatVoiceModePhase.muted => Colors.orange,
      ChatVoiceModePhase.error => Theme.of(context).colorScheme.error,
      _ => context.conduitTheme.textSecondary,
    };
    final size = compact ? 10.0 : 14.0 + snapshot.intensity.clamp(0, 10) * 0.8;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            child: RichText(
              key: ValueKey<String>(text),
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
    this.destructive = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return _AdaptiveVoiceAction(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: icon,
      destructive: destructive,
    );
  }
}

class _AdaptiveVoiceAction extends StatelessWidget {
  const _AdaptiveVoiceAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
    this.compact = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();
    final size = compact ? TouchTarget.micro : TouchTarget.medium;
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
          child: Icon(
            icon,
            size: compact ? IconSize.sm : IconSize.medium,
            color: iconColor,
            semanticLabel: tooltip,
          ),
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
