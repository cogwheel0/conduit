import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../theme/theme_extensions.dart';

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
        style: TextStyle(color: theme.textPrimary),
      ),
      content: content != null
          ? DefaultTextStyle(
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: 14,
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
            style: TextStyle(color: theme.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(
                effectiveCancelText,
                style: TextStyle(color: theme.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                effectiveConfirmText,
                style: TextStyle(
                  color: isDestructive
                      ? theme.error
                      : theme.buttonPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) {
        final theme = ctx.conduitTheme;
        return buildBase(
          context: ctx,
          title: title,
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: keyboardType,
            textCapitalization: textCapitalization,
            maxLength: maxLength,
            style: TextStyle(color: theme.textPrimary),
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: TextStyle(
                color: theme.textSecondary.withValues(alpha: 0.6),
              ),
              counterStyle: TextStyle(color: theme.textSecondary),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: theme.cardBorder,
                ),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: theme.buttonPrimary,
                  width: 2,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: Text(
                effectiveCancelText,
                style: TextStyle(color: theme.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(controller.text),
              child: Text(
                effectiveConfirmText,
                style: TextStyle(
                  color: theme.buttonPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (result == null) return null;
    final trimmed = result.trim();
    if (trimmed.isEmpty) return null;
    if (initialValue != null && trimmed == initialValue.trim()) return null;
    return trimmed;
  }
}
