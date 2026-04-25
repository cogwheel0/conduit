import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../theme/conduit_input_styles.dart';
import '../theme/theme_extensions.dart';
import 'conduit_components.dart';

/// Centralized helper for building themed dialogs consistently.
///
/// On iOS: delegates to [AdaptiveAlertDialog] for native Cupertino /
/// Liquid Glass chrome.
/// On Android: renders a [AlertDialog] explicitly themed with conduit
/// tokens so button colors, backgrounds, and text match the app palette.
class ThemedDialogs {
  ThemedDialogs._();

  /// Build a base themed [AlertDialog] widget.
  static AlertDialog buildBase({
    required BuildContext context,
    required String title,
    Widget? content,
    List<Widget>? actions,
  }) {
    final theme = context.conduitTheme;
    return AlertDialog(
      backgroundColor: theme.surfaces.popover,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppBorderRadius.dialog),
      ),
      title: Text(
        title,
        style: AppTypography.titleMediumStyle.copyWith(
          color: theme.textPrimary,
        ),
      ),
      content: content != null
          ? DefaultTextStyle(
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
              child: content,
            )
          : null,
      actions: actions,
    );
  }

  /// Show a simple confirmation dialog with Cancel/Confirm actions.
  ///
  /// On iOS uses [AdaptiveAlertDialog] for native chrome.
  /// On Android renders a fully themed [AlertDialog].
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmText,
    String? cancelText,
    bool isDestructive = false,
    bool barrierDismissible = true,
  }) async {
    final l10n = AppLocalizations.of(context);
    final effectiveConfirmText = confirmText ?? l10n?.confirm ?? 'Confirm';
    final effectiveCancelText = cancelText ?? l10n?.cancel ?? 'Cancel';

    if (Platform.isIOS) {
      final completer = Completer<bool>();
      await AdaptiveAlertDialog.show(
        context: context,
        title: title,
        message: message,
        actions: [
          AlertAction(
            title: effectiveCancelText,
            onPressed: () {
              if (!completer.isCompleted) completer.complete(false);
            },
            style: AlertActionStyle.cancel,
          ),
          AlertAction(
            title: effectiveConfirmText,
            onPressed: () {
              if (!completer.isCompleted) completer.complete(true);
            },
            style: isDestructive
                ? AlertActionStyle.destructive
                : AlertActionStyle.primary,
          ),
        ],
      );
      if (!completer.isCompleted) completer.complete(false);
      return completer.future;
    }

    // Android — fully themed Material dialog.
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) {
        final theme = ctx.conduitTheme;
        return buildBase(
          context: ctx,
          title: title,
          content: Text(
            message,
            style: AppTypography.bodyMediumStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          actions: [
            ConduitTextButton(
              text: effectiveCancelText,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            ConduitTextButton(
              text: effectiveConfirmText,
              onPressed: () => Navigator.of(ctx).pop(true),
              isDestructive: isDestructive,
              isPrimary: !isDestructive,
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  /// Show a generic themed dialog with arbitrary widget content.
  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    required Widget content,
    List<Widget>? actions,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) => buildBase(
        context: ctx,
        title: title,
        content: content,
        actions: actions,
      ),
    );
  }

  /// Text input dialog used for rename/create flows.
  ///
  /// On iOS uses [AdaptiveAlertDialog.inputShow] for native chrome.
  /// On Android renders a fully themed [AlertDialog] with [TextField].
  static Future<String?> promptTextInput(
    BuildContext context, {
    required String title,
    required String hintText,
    String? initialValue,
    String? confirmText,
    String? cancelText,
    bool barrierDismissible = true,
    TextInputType? keyboardType,
    TextCapitalization textCapitalization = TextCapitalization.sentences,
    int? maxLength,
  }) async {
    final l10n = AppLocalizations.of(context);
    final effectiveConfirmText = confirmText ?? l10n?.save ?? 'Save';
    final effectiveCancelText = cancelText ?? l10n?.cancel ?? 'Cancel';

    if (Platform.isIOS) {
      final result = await AdaptiveAlertDialog.inputShow(
        context: context,
        title: title,
        actions: [
          AlertAction(
            title: effectiveCancelText,
            onPressed: () {},
            style: AlertActionStyle.cancel,
          ),
          AlertAction(
            title: effectiveConfirmText,
            onPressed: () {},
            style: AlertActionStyle.primary,
          ),
        ],
        input: AdaptiveAlertDialogInput(
          placeholder: hintText,
          initialValue: initialValue,
          keyboardType: keyboardType,
          maxLength: maxLength,
        ),
      );
      if (result == null) return null;
      final trimmed = result.trim();
      if (trimmed.isEmpty) return null;
      if (initialValue != null && trimmed == initialValue.trim()) return null;
      return trimmed;
    }

    // Android — fully themed Material dialog with TextField.
    // The controller is owned by _TextInputDialogContent so its lifecycle
    // is tied to the dialog widget tree (survives dismiss animation).
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) => _TextInputDialogContent(
        title: title,
        hintText: hintText,
        initialValue: initialValue,
        confirmText: effectiveConfirmText,
        cancelText: effectiveCancelText,
        keyboardType: keyboardType,
        textCapitalization: textCapitalization,
        maxLength: maxLength,
      ),
    );
    if (result == null) return null;
    final trimmed = result.trim();
    if (trimmed.isEmpty) return null;
    if (initialValue != null && trimmed == initialValue.trim()) return null;
    return trimmed;
  }
}

/// Material text-input dialog that owns its own [TextEditingController].
///
/// This prevents the "used after being disposed" error that occurs when a
/// controller is disposed while the dialog dismiss animation is still running.
class _TextInputDialogContent extends StatefulWidget {
  const _TextInputDialogContent({
    required this.title,
    required this.hintText,
    required this.confirmText,
    required this.cancelText,
    this.initialValue,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.sentences,
    this.maxLength,
  });

  final String title;
  final String hintText;
  final String confirmText;
  final String cancelText;
  final String? initialValue;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final int? maxLength;

  @override
  State<_TextInputDialogContent> createState() =>
      _TextInputDialogContentState();
}

class _TextInputDialogContentState extends State<_TextInputDialogContent> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return ThemedDialogs.buildBase(
      context: context,
      title: widget.title,
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: widget.keyboardType,
        textCapitalization: widget.textCapitalization,
        maxLength: widget.maxLength,
        style: AppTypography.bodyMediumStyle.copyWith(color: theme.textPrimary),
        decoration: context.conduitInputStyles
            .underline(hint: widget.hintText)
            .copyWith(
              counterStyle: AppTypography.labelSmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
      ),
      actions: [
        ConduitTextButton(
          text: widget.cancelText,
          onPressed: () => Navigator.of(context).pop(null),
        ),
        ConduitTextButton(
          text: widget.confirmText,
          onPressed: () => Navigator.of(context).pop(_controller.text),
          isPrimary: true,
        ),
      ],
    );
  }
}
