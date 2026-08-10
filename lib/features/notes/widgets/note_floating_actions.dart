import 'dart:io' show Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';

enum _NoteEnhancementAction { enhance, title }

/// Platform-adaptive voice and AI actions for the note editor.
class NoteFloatingActions extends StatelessWidget {
  const NoteFloatingActions({
    super.key,
    required this.isRecording,
    required this.isUploadingAudio,
    required this.isEnhancing,
    required this.onVoicePressed,
    required this.onEnhance,
    required this.onGenerateTitle,
  });

  final bool isRecording;
  final bool isUploadingAudio;
  final bool isEnhancing;
  final VoidCallback onVoicePressed;
  final VoidCallback onEnhance;
  final VoidCallback onGenerateTitle;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _FloatingActionButton(
          nativeSymbol: isRecording ? 'stop.fill' : 'mic.fill',
          icon: isRecording
              ? (Platform.isIOS ? CupertinoIcons.stop_fill : Icons.stop_rounded)
              : (Platform.isIOS ? CupertinoIcons.mic_fill : Icons.mic_rounded),
          color: isRecording ? theme.error : null,
          isLoading: isUploadingAudio,
          tooltip: isRecording ? l10n.stopRecording : l10n.voiceOptions,
          onPressed: isUploadingAudio ? null : onVoicePressed,
        ),
        _FloatingActionButton(
          nativeSymbol: 'sparkles',
          icon: Platform.isIOS
              ? CupertinoIcons.sparkles
              : Icons.auto_awesome_rounded,
          isLoading: isEnhancing,
          tooltip: l10n.enhanceWithAI,
          onPressed: isEnhancing ? null : onEnhance,
          enhancementActions: {
            _NoteEnhancementAction.enhance: l10n.enhanceNote,
            _NoteEnhancementAction.title: l10n.generateTitle,
          },
          onEnhancementSelected: (action) => switch (action) {
            _NoteEnhancementAction.enhance => onEnhance(),
            _NoteEnhancementAction.title => onGenerateTitle(),
          },
        ),
      ],
    );
  }
}

class _FloatingActionButton extends StatelessWidget {
  const _FloatingActionButton({
    required this.nativeSymbol,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isLoading = false,
    this.color,
    this.enhancementActions,
    this.onEnhancementSelected,
  });

  final String nativeSymbol;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isLoading;
  final Color? color;
  final Map<_NoteEnhancementAction, String>? enhancementActions;
  final ValueChanged<_NoteEnhancementAction>? onEnhancementSelected;

  @override
  Widget build(BuildContext context) {
    final button = _AdaptiveFloatingButton(
      nativeSymbol: nativeSymbol,
      icon: icon,
      onPressed: onPressed,
      isLoading: isLoading,
      color: color,
    );
    final actions = enhancementActions;

    if (actions != null) {
      final items = [
        for (final entry in actions.entries)
          AdaptivePopupMenuItem<_NoteEnhancementAction>(
            label: entry.value,
            value: entry.key,
            icon: switch (entry.key) {
              _NoteEnhancementAction.enhance =>
                Platform.isIOS ? 'wand.and.stars' : Icons.auto_fix_high_rounded,
              _NoteEnhancementAction.title =>
                Platform.isIOS ? 'textformat' : Icons.title_rounded,
            },
          ),
      ];

      if (conduitSupportsNativeGlass() && !isLoading) {
        return AdaptiveTooltip(
          message: tooltip,
          child: Semantics(
            button: true,
            label: tooltip,
            child: AdaptivePopupMenuButton.icon<_NoteEnhancementAction>(
              key: const ValueKey<String>('note-ai-native-glass-menu'),
              icon: nativeSymbol,
              items: items,
              onSelected: (_, entry) {
                final action = entry.value;
                if (action != null) onEnhancementSelected?.call(action);
              },
              size: TouchTarget.button,
              iconSize: IconSize.md,
              buttonStyle: PopupButtonStyle.glass,
            ),
          ),
        );
      }

      return AdaptiveTooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          child: AdaptivePopupMenuButton.widget<_NoteEnhancementAction>(
            items: items,
            onSelected: (_, entry) {
              final action = entry.value;
              if (action != null) onEnhancementSelected?.call(action);
            },
            child: IgnorePointer(child: button),
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: tooltip,
      enabled: onPressed != null,
      child: AdaptiveTooltip(message: tooltip, child: button),
    );
  }
}

class _AdaptiveFloatingButton extends StatelessWidget {
  const _AdaptiveFloatingButton({
    required this.nativeSymbol,
    required this.icon,
    required this.onPressed,
    required this.isLoading,
    this.color,
  });

  final String nativeSymbol;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool isLoading;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final labelColor = theme.textPrimary;
    final borderRadius = BorderRadius.circular(AppBorderRadius.floatingButton);
    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();
    final effectiveColor = usesOpaqueFallback && color == null
        ? theme.surfaceContainerHighest
        : color;

    if (conduitSupportsNativeGlass()) {
      if (isLoading) {
        return SizedBox.square(
          key: const ValueKey<String>('note-floating-native-glass-loading'),
          dimension: TouchTarget.button,
          child: Stack(
            children: [
              Positioned.fill(
                child: AdaptiveGlassBackdrop(borderRadius: borderRadius),
              ),
              Center(
                child: SizedBox(
                  width: IconSize.md,
                  height: IconSize.md,
                  child: CircularProgressIndicator(
                    strokeWidth: BorderWidth.medium,
                    valueColor: AlwaysStoppedAnimation(labelColor),
                  ),
                ),
              ),
            ],
          ),
        );
      }

      return AdaptiveButton.sfSymbol(
        key: const ValueKey<String>('note-floating-native-glass-button'),
        onPressed: onPressed,
        enabled: onPressed != null,
        sfSymbol: SFSymbol(
          nativeSymbol,
          size: IconSize.md,
          color: color == null ? labelColor : Colors.white,
        ),
        color: color,
        style: color == null
            ? AdaptiveButtonStyle.glass
            : AdaptiveButtonStyle.prominentGlass,
        size: AdaptiveButtonSize.large,
        minSize: const Size.square(TouchTarget.button),
        padding: EdgeInsets.zero,
        borderRadius: borderRadius,
        useSmoothRectangleBorder: false,
      );
    }

    return AdaptiveButton.child(
      onPressed: onPressed,
      enabled: onPressed != null,
      color: effectiveColor,
      style: usesOpaqueFallback
          ? AdaptiveButtonStyle.filled
          : color == null
          ? AdaptiveButtonStyle.glass
          : AdaptiveButtonStyle.prominentGlass,
      size: AdaptiveButtonSize.large,
      minSize: const Size(TouchTarget.button, TouchTarget.button),
      padding: EdgeInsets.zero,
      borderRadius: borderRadius,
      useSmoothRectangleBorder: false,
      child: SizedBox(
        width: TouchTarget.button,
        height: TouchTarget.button,
        child: Center(
          child: isLoading
              ? SizedBox(
                  width: IconSize.md,
                  height: IconSize.md,
                  child: CircularProgressIndicator(
                    strokeWidth: BorderWidth.medium,
                    valueColor: AlwaysStoppedAnimation(labelColor),
                  ),
                )
              : Icon(
                  icon,
                  color: color == null ? labelColor : Colors.white,
                  size: IconSize.md,
                ),
        ),
      ),
    );
  }
}
