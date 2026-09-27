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
    UiTextInputType inputType = UiTextInputType.text,
    List<UiSelectOption> options = const [],
    String? confirmLabel,
    String? cancelLabel,
  }) async {
    final ctx = NavigationService.context;
    if (ctx == null) return null;

    return ThemedDialogs.showCustom<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => _TextInputDialog(
        title: title,
        message: message,
        placeholder: placeholder,
        initialValue: initialValue,
        inputType: inputType,
        options: options,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
      ),
    );
  }
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.message,
    required this.placeholder,
    required this.initialValue,
    required this.inputType,
    required this.options,
    required this.confirmLabel,
    required this.cancelLabel,
  });

  final String title;
  final String message;
  final String? placeholder;
  final String? initialValue;
  final UiTextInputType inputType;
  final List<UiSelectOption> options;
  final String? confirmLabel;
  final String? cancelLabel;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final _controller = TextEditingController(
    text: widget.initialValue ?? '',
  );
  late final _choices = {
    for (final option in widget.options) option.value: option.label,
  };
  late String? _selection = _choices.containsKey(widget.initialValue)
      ? widget.initialValue
      : null;
  bool get _isSelect =>
      widget.inputType == UiTextInputType.select && _choices.isNotEmpty;

  String? _answer() {
    final value = _isSelect ? _selection : _controller.text;
    return value == null || value.isEmpty ? null : value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemedDialogs.buildBase(
      context: context,
      title: widget.title,
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message.isNotEmpty) ...[
            Text(
              widget.message,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: context.conduitTheme.textSecondary,
              ),
            ),
            const SizedBox(height: Spacing.md),
          ],
          if (_isSelect)
            DropdownButtonFormField<String>(
              initialValue: _selection,
              isExpanded: true,
              hint: widget.placeholder == null
                  ? null
                  : Text(widget.placeholder!),
              items: [
                for (final entry in _choices.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) => setState(() => _selection = value),
            )
          else
            AdaptiveTextField(
              controller: _controller,
              obscureText: widget.inputType == UiTextInputType.password,
              autocorrect: widget.inputType != UiTextInputType.password,
              enableSuggestions: widget.inputType != UiTextInputType.password,
              autofocus: true,
              placeholder: widget.placeholder?.isNotEmpty == true
                  ? widget.placeholder
                  : 'Enter a value',
              onSubmitted: (_) => Navigator.of(context).pop(_answer()),
            ),
        ],
      ),
      actions: [
        AdaptiveButton(
          onPressed: () => Navigator.of(context).pop(null),
          label: widget.cancelLabel ?? 'Cancel',
          textColor: context.conduitTheme.textSecondary,
          style: AdaptiveButtonStyle.plain,
        ),
        AdaptiveButton(
          onPressed: () => Navigator.of(context).pop(_answer()),
          label: widget.confirmLabel ?? 'Submit',
          textColor: context.conduitTheme.buttonPrimary,
          style: AdaptiveButtonStyle.plain,
        ),
      ],
    );
  }
}
