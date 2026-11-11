import 'dart:async';
import 'dart:math' as math;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
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
    bool scrollable = false,
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
      scrollable: scrollable,
    );
  }

  /// Asks a yes/no question with Cancel and Confirm actions, and resolves to
  /// true only when the user confirms. Cancelling or dismissing resolves to
  /// false.
  ///
  /// On iOS 26 and later the question takes the system's form: a destructive
  /// one ([isDestructive]: delete, discard, sign out) is an action sheet, and
  /// any other one is an alert. Pass [anchorContext], the widget the question
  /// came from such as the button that was tapped, and the action sheet
  /// appears over that widget; without one it rises from the bottom of the
  /// screen. A system alert or action sheet ignores [barrierDismissible]: an
  /// alert never closes on an outside tap, and an action sheet always does,
  /// which answers false.
  ///
  /// Earlier iOS shows a Cupertino alert, and Android a themed Material
  /// dialog.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmText,
    String? cancelText,
    bool isDestructive = false,
    bool barrierDismissible = true,
    BuildContext? anchorContext,
  }) async {
    final l10n = AppLocalizations.of(context);
    final effectiveConfirmText = confirmText ?? l10n?.confirm ?? 'Confirm';
    final effectiveCancelText = cancelText ?? l10n?.cancel ?? 'Cancel';

    if (PlatformUiCapabilities.usesNativeIOS26 && isDestructive) {
      final confirmed =
          await CNActionSheet.show<bool>(
            context: context,
            title: title,
            message: message,
            actions: [
              CNActionSheetAction<bool>(
                label: effectiveConfirmText,
                value: true,
                isDestructive: true,
              ),
            ],
            cancelLabel: effectiveCancelText,
            anchorRect: _actionSheetAnchor(context, anchorContext),
          ) ??
          false;
      if (confirmed) unawaited(ConduitHaptics.mediumImpact());
      return confirmed;
    }

    if (PlatformUiCapabilities.isIOS) {
      // The system alert from iOS 26 answers a press with no haptic of its
      // own; the earlier Cupertino alert keeps its behaviour.
      final answerHaptic = PlatformUiCapabilities.usesNativeIOS26;
      final completer = Completer<bool>();
      await AdaptiveAlertDialog.show(
        context: context,
        title: title,
        message: message,
        actions: [
          AlertAction(
            title: effectiveCancelText,
            onPressed: () {
              if (answerHaptic) unawaited(ConduitHaptics.selectionClick());
              if (!completer.isCompleted) completer.complete(false);
            },
            style: AlertActionStyle.cancel,
          ),
          AlertAction(
            title: effectiveConfirmText,
            onPressed: () {
              if (answerHaptic) unawaited(ConduitHaptics.selectionClick());
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

  /// Where an action sheet appears: over [anchorContext] when it is laid
  /// out, else, on iPhone, at the bottom of the screen above the keyboard and
  /// the home indicator. iOS 26 centres a sheet with no anchor, like an
  /// alert. An iPad is left to the package, which gives such a sheet a
  /// source at the bottom of the window.
  static Rect? _actionSheetAnchor(
    BuildContext context,
    BuildContext? anchorContext,
  ) {
    if (anchorContext != null && anchorContext.mounted) {
      final box = anchorContext.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) {
        return box.localToGlobal(Offset.zero) & box.size;
      }
    }
    final view = View.maybeOf(context);
    if (view == null) return null;
    final display = view.display;
    if (display.size.shortestSide / display.devicePixelRatio >= 600) {
      return null;
    }
    final ratio = view.devicePixelRatio;
    final size = view.physicalSize / ratio;
    final bottomInset =
        math.max(view.viewPadding.bottom, view.viewInsets.bottom) / ratio;
    return Rect.fromLTWH(size.width / 2, size.height - bottomInset, 0, 0);
  }

  /// Show a generic themed dialog with arbitrary widget content.
  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    required Widget content,
    List<Widget>? actions,
    bool barrierDismissible = true,
  }) {
    return showCustom<T>(
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

  /// Show custom dialog content through the shared dialog route defaults.
  static Future<T?> showCustom<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: builder,
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

    final nativeEditorPreservesInputConfiguration =
        keyboardType == null &&
        textCapitalization == TextCapitalization.sentences &&
        (maxLength == null || maxLength == TextField.noMaxLength);
    if (PlatformUiCapabilities.usesNativeIOS26 &&
        nativeEditorPreservesInputConfiguration) {
      try {
        final result = await NativeSheetBridge.instance.presentTextEditor(
          title: title,
          value: initialValue ?? '',
          placeholder: hintText,
          sendLabel: effectiveConfirmText,
          valueId: 'text',
          sendActionId: 'confirm',
          closeActionId: 'cancel',
          rethrowErrors: true,
        );
        if (result?.actionId != 'confirm') return null;
        final value = result?.values['text'];
        if (value is! String) return null;
        final bounded = maxLength == null || maxLength == TextField.noMaxLength
            ? value
            : value.characters.take(maxLength).toString();
        final trimmed = bounded.trim();
        if (trimmed.isEmpty) return null;
        if (initialValue != null && trimmed == initialValue.trim()) return null;
        return trimmed;
      } catch (_) {
        // Fall through to the Flutter Cupertino dialog when the bridge fails.
      }
      if (!context.mounted) return null;
    }

    if (PlatformUiCapabilities.isIOS) {
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
        magnifierConfiguration: nativeIosTextMagnifierConfiguration,
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
