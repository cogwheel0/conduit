import 'dart:async';

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'platform_ui_capabilities.dart';

enum AdaptiveSnackBarType { info, success, warning, error }

class AdaptiveSnackBar {
  AdaptiveSnackBar._();

  static OverlayEntry? _activeIOSEntry;

  static void show(
    BuildContext context, {
    required String message,
    AdaptiveSnackBarType type = AdaptiveSnackBarType.info,
    Duration duration = const Duration(seconds: 4),
    String? action,
    VoidCallback? onActionPressed,
  }) {
    final nativeDuration = _nativeDuration(duration);
    if (PlatformUiCapabilities.usesNativeIOS26 &&
        action == null &&
        nativeDuration != null) {
      final style = switch (type) {
        AdaptiveSnackBarType.info => CNToastStyle.info,
        AdaptiveSnackBarType.success => CNToastStyle.success,
        AdaptiveSnackBarType.warning => CNToastStyle.warning,
        AdaptiveSnackBarType.error => CNToastStyle.error,
      };
      CNToast.show(
        context: context,
        message: message,
        position: CNToastPosition.top,
        duration: nativeDuration,
        style: style,
      );
      return;
    }

    if (!PlatformUiCapabilities.isIOS) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: duration,
          backgroundColor: switch (type) {
            AdaptiveSnackBarType.info => Theme.of(
              context,
            ).snackBarTheme.backgroundColor,
            AdaptiveSnackBarType.success => Colors.green.shade700,
            AdaptiveSnackBarType.warning => Colors.orange.shade700,
            AdaptiveSnackBarType.error => Colors.red.shade700,
          },
          action: action == null
              ? null
              : SnackBarAction(
                  label: action,
                  onPressed: onActionPressed ?? () {},
                ),
        ),
      );
      return;
    }

    final overlay = Overlay.of(context);
    final previousEntry = _activeIOSEntry;
    if (previousEntry?.mounted == true) previousEntry!.remove();
    _activeIOSEntry = null;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _IOSBanner(
        message: message,
        type: type,
        duration: duration,
        action: action,
        onActionPressed: onActionPressed,
        onDismiss: () {
          if (entry.mounted) entry.remove();
          if (identical(_activeIOSEntry, entry)) _activeIOSEntry = null;
        },
      ),
    );
    _activeIOSEntry = entry;
    overlay.insert(entry);
  }

  static CNToastDuration? _nativeDuration(Duration value) {
    if (value == const Duration(seconds: 2)) return CNToastDuration.short;
    if (value == const Duration(milliseconds: 3500)) {
      return CNToastDuration.medium;
    }
    if (value == const Duration(seconds: 5)) return CNToastDuration.long;
    return null;
  }
}

class _IOSBanner extends StatefulWidget {
  const _IOSBanner({
    required this.message,
    required this.type,
    required this.duration,
    required this.onDismiss,
    this.action,
    this.onActionPressed,
  });

  final String message;
  final AdaptiveSnackBarType type;
  final Duration duration;
  final String? action;
  final VoidCallback? onActionPressed;
  final VoidCallback onDismiss;

  @override
  State<_IOSBanner> createState() => _IOSBannerState();
}

class _IOSBannerState extends State<_IOSBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, widget.onDismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tint = switch (widget.type) {
      AdaptiveSnackBarType.info => CupertinoColors.systemBlue,
      AdaptiveSnackBarType.success => CupertinoColors.systemGreen,
      AdaptiveSnackBarType.warning => CupertinoColors.systemOrange,
      AdaptiveSnackBarType.error => CupertinoColors.systemRed,
    };
    final icon = switch (widget.type) {
      AdaptiveSnackBarType.info => CupertinoIcons.info_circle_fill,
      AdaptiveSnackBarType.success => CupertinoIcons.check_mark_circled_solid,
      AdaptiveSnackBarType.warning =>
        CupertinoIcons.exclamationmark_triangle_fill,
      AdaptiveSnackBarType.error => CupertinoIcons.xmark_circle_fill,
    };
    return Positioned(
      top: 8,
      left: 12,
      right: 12,
      child: SafeArea(
        bottom: false,
        child: Semantics(
          liveRegion: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: CupertinoColors.secondarySystemBackground.resolveFrom(
                context,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x26000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(icon, color: tint, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.message,
                      style: TextStyle(
                        color: CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                  ),
                  if (widget.action != null)
                    CupertinoButton(
                      padding: const EdgeInsets.only(left: 10),
                      minimumSize: const Size(36, 36),
                      onPressed: () {
                        widget.onActionPressed?.call();
                        widget.onDismiss();
                      },
                      child: Text(widget.action!),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum AlertActionStyle {
  defaultAction,
  cancel,
  destructive,
  primary,
  secondary,
  success,
  warning,
  info,
  disabled,
}

class AlertAction {
  const AlertAction({
    required this.title,
    required this.onPressed,
    this.style = AlertActionStyle.defaultAction,
    this.enabled = true,
  });

  final String title;
  final VoidCallback onPressed;
  final AlertActionStyle style;
  final bool enabled;
}

class AdaptiveAlertDialogInput {
  const AdaptiveAlertDialogInput({
    required this.placeholder,
    this.initialValue,
    this.keyboardType,
    this.obscureText = false,
    this.maxLength,
  });

  final String placeholder;
  final String? initialValue;
  final TextInputType? keyboardType;
  final bool obscureText;
  final int? maxLength;
}

class AdaptiveAlertDialog {
  AdaptiveAlertDialog._();

  static Future<void> show({
    required BuildContext context,
    required String title,
    String? message,
    required List<AlertAction> actions,
  }) async {
    if (PlatformUiCapabilities.isIOS) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(title),
          content: message == null ? null : Text(message),
          actions: [
            for (final action in actions)
              CupertinoDialogAction(
                onPressed:
                    !action.enabled || action.style == AlertActionStyle.disabled
                    ? null
                    : () {
                        Navigator.of(dialogContext).pop();
                        action.onPressed();
                      },
                isDefaultAction: action.style == AlertActionStyle.primary,
                isDestructiveAction:
                    action.style == AlertActionStyle.destructive,
                child: Text(action.title),
              ),
          ],
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: message == null ? null : Text(message),
        actions: [
          for (final action in actions)
            TextButton(
              style: action.style == AlertActionStyle.destructive
                  ? TextButton.styleFrom(
                      foregroundColor: Theme.of(
                        dialogContext,
                      ).colorScheme.error,
                    )
                  : null,
              onPressed:
                  !action.enabled || action.style == AlertActionStyle.disabled
                  ? null
                  : () {
                      Navigator.of(dialogContext).pop();
                      action.onPressed();
                    },
              child: Text(action.title),
            ),
        ],
      ),
    );
  }

  static Future<String?> inputShow({
    required BuildContext context,
    required String title,
    String? message,
    required List<AlertAction> actions,
    required AdaptiveAlertDialogInput input,
  }) async {
    final controller = TextEditingController(text: input.initialValue);
    try {
      if (PlatformUiCapabilities.isIOS) {
        return await showCupertinoDialog<String?>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message != null) Text(message),
                const SizedBox(height: 10),
                CupertinoTextField(
                  controller: controller,
                  placeholder: input.placeholder,
                  keyboardType: input.keyboardType,
                  obscureText: input.obscureText,
                  maxLength: input.maxLength,
                  autofocus: true,
                ),
              ],
            ),
            actions: [
              for (final action in actions)
                CupertinoDialogAction(
                  onPressed:
                      !action.enabled ||
                          action.style == AlertActionStyle.disabled
                      ? null
                      : () {
                          final isCancel =
                              action.style == AlertActionStyle.cancel;
                          Navigator.of(
                            dialogContext,
                          ).pop(isCancel ? null : controller.text);
                          action.onPressed();
                        },
                  isDefaultAction: action.style == AlertActionStyle.primary,
                  isDestructiveAction:
                      action.style == AlertActionStyle.destructive,
                  child: Text(action.title),
                ),
            ],
          ),
        );
      }
      return await showDialog<String?>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            keyboardType: input.keyboardType,
            obscureText: input.obscureText,
            maxLength: input.maxLength,
            autofocus: true,
            decoration: InputDecoration(hintText: input.placeholder),
          ),
          actions: [
            for (final action in actions)
              TextButton(
                style: action.style == AlertActionStyle.destructive
                    ? TextButton.styleFrom(
                        foregroundColor: Theme.of(
                          dialogContext,
                        ).colorScheme.error,
                      )
                    : null,
                onPressed:
                    !action.enabled || action.style == AlertActionStyle.disabled
                    ? null
                    : () {
                        Navigator.of(dialogContext).pop(
                          action.style == AlertActionStyle.cancel
                              ? null
                              : controller.text,
                        );
                        action.onPressed();
                      },
                child: Text(action.title),
              ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }
}
