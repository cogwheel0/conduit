import 'dart:async';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../theme/theme_extensions.dart';

/// Centralized helper for building themed dialogs consistently.
///
/// Methods that need simple confirm/cancel or text-input flows
/// delegate to [AdaptiveAlertDialog] so the dialog renders with
/// platform-native chrome on every OS. Methods that require
/// arbitrary widget content (`show`, `buildBase`) still fall back
/// to [AlertDialog] because [AdaptiveAlertDialog] only accepts
/// plain-text messages.
class ThemedDialogs {
  ThemedDialogs._();

  /// Build a base themed [AlertDialog] widget.
  ///
  /// This returns a widget directly (not a Future) and is used by
  /// callers that need to embed custom widget content or actions
  /// inside a `showDialog` builder. Because [AdaptiveAlertDialog]
  /// is a static utility that only accepts string messages, this
  /// method intentionally remains as a raw [AlertDialog].
  static AlertDialog buildBase({
    required BuildContext context,
    required String title,
    Widget? content,
    List<Widget>? actions,
  }) {
    return AlertDialog(
      backgroundColor: context.conduitTheme.surfaceBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          AppBorderRadius.dialog,
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: context.conduitTheme.textPrimary,
        ),
      ),
      content: content,
      actions: actions,
    );
  }

  /// Show a simple confirmation dialog with Cancel/Confirm actions.
  ///
  /// Returns `true` when the user taps confirm, `false` when they
  /// tap cancel or dismiss the dialog. Uses a [Completer] to bridge
  /// [AdaptiveAlertDialog.show]'s callback-based API to the
  /// expected [Future<bool>] return value.
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
    final effectiveConfirmText =
        confirmText ?? l10n?.confirm ?? 'Confirm';
    final effectiveCancelText =
        cancelText ?? l10n?.cancel ?? 'Cancel';

    final completer = Completer<bool>();

    await AdaptiveAlertDialog.show(
      context: context,
      title: title,
      message: message,
      actions: [
        AlertAction(
          title: effectiveCancelText,
          onPressed: () {
            if (!completer.isCompleted) {
              completer.complete(false);
            }
          },
          style: AlertActionStyle.cancel,
        ),
        AlertAction(
          title: effectiveConfirmText,
          onPressed: () {
            if (!completer.isCompleted) {
              completer.complete(true);
            }
          },
          style: isDestructive
              ? AlertActionStyle.destructive
              : AlertActionStyle.primary,
        ),
      ],
    );

    // If dismissed without pressing any action, return false.
    if (!completer.isCompleted) {
      completer.complete(false);
    }

    return completer.future;
  }

  /// Show a generic themed dialog with arbitrary widget content.
  ///
  /// Because [AdaptiveAlertDialog] only accepts plain-text
  /// messages, this method intentionally remains as a raw
  /// [showDialog] + [AlertDialog] so callers can pass rich widget
  /// trees for [content] and [actions].
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

  /// Cohesive text input dialog used for rename/create flows.
  ///
  /// Delegates to [AdaptiveAlertDialog.inputShow] so the dialog
  /// renders with platform-native chrome (Liquid Glass on iOS 26+,
  /// Cupertino on older iOS, Material on Android).
  static Future<String?> promptTextInput(
    BuildContext context, {
    required String title,
    required String hintText,
    String? initialValue,
    String? confirmText,
    String? cancelText,
    bool barrierDismissible = true,
    TextInputType? keyboardType,
    TextCapitalization textCapitalization =
        TextCapitalization.sentences,
    int? maxLength,
  }) async {
    final l10n = AppLocalizations.of(context);
    final effectiveConfirmText =
        confirmText ?? l10n?.save ?? 'Save';
    final effectiveCancelText =
        cancelText ?? l10n?.cancel ?? 'Cancel';

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

    // If the value is unchanged from the initial value, treat it
    // as a cancellation to match the previous behaviour.
    if (initialValue != null &&
        trimmed == initialValue.trim()) {
      return null;
    }

    return trimmed;
  }
}
