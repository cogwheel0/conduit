import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/theme_extensions.dart';
import '../widgets/themed_dialogs.dart';
import 'navigation_service.dart';

/// The Flutter app's [UiRequestPort].
///
/// These three dialogs used to live inside `streaming_helper.dart`, which is
/// why that file reached for `NavigationService.context` and built widgets
/// mid-stream. Deciding *when* to ask is streaming logic and stayed there;
/// rendering the question is presentation and moved here.
///
/// Every method degrades the same way the originals did: with no navigator
/// context there is nobody to ask, so a confirmation declines and a prompt
/// cancels rather than hanging the stream.
class FlutterUiRequests implements UiRequestPort {
  const FlutterUiRequests();

  @override
  void notify(UiNoticeLevel level, String message) {
    if (message.isEmpty) return;
    final ctx = NavigationService.context;
    if (ctx == null) return;

    AdaptiveSnackBar.show(
      ctx,
      message: message,
      type: switch (level) {
        UiNoticeLevel.success => AdaptiveSnackBarType.success,
        UiNoticeLevel.error => AdaptiveSnackBarType.error,
        UiNoticeLevel.warning => AdaptiveSnackBarType.warning,
        UiNoticeLevel.info => AdaptiveSnackBarType.info,
      },
      duration: const Duration(seconds: 4),
    );
  }

  @override
  Future<bool> confirm({
    required String title,
    String message = '',
    String? confirmLabel,
    String? cancelLabel,
  }) async {
    final ctx = NavigationService.context;
    if (ctx == null) return false;

    return ThemedDialogs.confirm(
      ctx,
      title: title,
      message: message,
      confirmText: confirmLabel ?? 'Confirm',
      cancelText: cancelLabel ?? 'Cancel',
      // The server is waiting on an answer; a stray tap outside must not
      // count as one.
      barrierDismissible: false,
    );
  }

  @override
  Future<String?> promptForText({
    required String title,
    String message = '',
    String? placeholder,
    String? initialValue,
    String? confirmLabel,
    String? cancelLabel,
  }) async {
    final ctx = NavigationService.context;
    if (ctx == null) return null;

    final controller = TextEditingController(text: initialValue ?? '');
    final result = await ThemedDialogs.showCustom<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return ThemedDialogs.buildBase(
          context: dialogCtx,
          title: title,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.isNotEmpty) ...[
                Text(
                  message,
                  style: AppTypography.bodyMediumStyle.copyWith(
                    color: dialogCtx.conduitTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: Spacing.md),
              ],
              AdaptiveTextField(
                controller: controller,
                autofocus: true,
                placeholder: (placeholder == null || placeholder.isEmpty)
                    ? 'Enter a value'
                    : placeholder,
                onSubmitted: (value) => Navigator.of(
                  dialogCtx,
                ).pop(value.trim().isEmpty ? null : value.trim()),
              ),
            ],
          ),
          actions: [
            AdaptiveButton(
              onPressed: () => Navigator.of(dialogCtx).pop(null),
              label: cancelLabel ?? 'Cancel',
              textColor: dialogCtx.conduitTheme.textSecondary,
              style: AdaptiveButtonStyle.plain,
            ),
            AdaptiveButton(
              onPressed: () {
                final trimmed = controller.text.trim();
                Navigator.of(dialogCtx).pop(trimmed.isEmpty ? null : trimmed);
              },
              label: confirmLabel ?? 'Submit',
              textColor: dialogCtx.conduitTheme.buttonPrimary,
              style: AdaptiveButtonStyle.plain,
            ),
          ],
        );
      },
    );

    controller.dispose();
    final trimmed = result?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
