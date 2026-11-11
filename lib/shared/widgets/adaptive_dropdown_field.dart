import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/services/haptic_service.dart';
import '../../core/services/ios_native_dropdown_bridge.dart';
import '../theme/theme_extensions.dart';
import 'platform_ui/platform_ui.dart';
import 'themed_sheets.dart';

@immutable
class AdaptiveDropdownOption<T> {
  const AdaptiveDropdownOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.iosSymbol,
    this.enabled = true,
  });

  final T value;
  final String label;
  final String? subtitle;
  final String? iosSymbol;
  final bool enabled;
}

/// Form-aware single-choice field that uses native iOS controls
/// and preserves the standard Material dropdown on other platforms.
class AdaptiveDropdownField<T> extends StatelessWidget {
  const AdaptiveDropdownField({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.decoration,
    this.textStyle,
    this.validator,
    this.nativeTitle,
    this.semanticLabel,
    this.cancelLabel,
    this.isExpanded = true,
  });

  final T? value;
  final List<AdaptiveDropdownOption<T>> options;
  final ValueChanged<T>? onChanged;
  final InputDecoration decoration;
  final TextStyle? textStyle;
  final FormFieldValidator<T>? validator;
  final String? nativeTitle;

  /// Field name included in the native control's accessibility label.
  final String? semanticLabel;
  final String? cancelLabel;
  final bool isExpanded;

  /// The native pop-up button's value while no option is selected.
  static const _noSelection = -1;

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfo.isIOS) {
      return DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: isExpanded,
        decoration: decoration,
        dropdownColor: context.conduitTheme.surfaceBackground,
        style: textStyle,
        validator: validator,
        items: [
          for (final option in options)
            DropdownMenuItem<T>(
              value: option.value,
              enabled: option.enabled,
              child: Text(option.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged == null
            ? null
            : (next) {
                for (final option in options) {
                  if (option.value == next) {
                    ConduitHaptics.selectionClick();
                    onChanged!(option.value);
                    return;
                  }
                }
              },
      );
    }

    return FormField<T>(
      key: ValueKey<Object?>((key, value)),
      initialValue: value,
      validator: validator,
      enabled: onChanged != null,
      builder: (state) {
        final selectedIndex = options.indexWhere(
          (option) => option.value == state.value,
        );
        final selected = selectedIndex < 0 ? null : options[selectedIndex];
        final effectiveDecoration = decoration.copyWith(
          enabled: onChanged != null,
          errorText: state.errorText,
        );
        // UIKit's pop-up button has no item subtitles; those lists keep the
        // native single-choice sheet below. It cannot lay out inside a
        // Material dialog either, which sizes itself to its content.
        if (PlatformUiCapabilities.usesNativeIOS26 &&
            !isInsideMaterialAlertDialog(context) &&
            options.isNotEmpty &&
            options.every((option) => option.subtitle?.isNotEmpty != true)) {
          final fieldName =
              semanticLabel ?? decoration.labelText ?? nativeTitle;
          return InputDecorator(
            // Keep the form decoration; UIKit presents the anchored menu.
            decoration: effectiveDecoration.copyWith(
              contentPadding: EdgeInsets.zero,
            ),
            isEmpty: false,
            child: SizedBox(
              width: double.infinity,
              child: CNPopUpButton<int>(
                // Options are matched by index: T need not be a valid
                // platform value, and a null T can still be chosen.
                value: selected == null ? _noSelection : selectedIndex,
                items: [
                  // With nothing chosen, the button shows the hint; UIKit
                  // titles a pop-up button with its selected item, so the
                  // hint is that item, dimmed so it can't be chosen back.
                  if (selected == null) ...[
                    CNPopUpButtonItem<int>(
                      value: _noSelection,
                      label: decoration.hintText ?? '',
                      enabled: false,
                    ),
                    const CNPopUpButtonDivider<int>(),
                  ],
                  for (final (index, option) in options.indexed)
                    CNPopUpButtonItem<int>(
                      value: index,
                      label: option.label,
                      enabled: option.enabled,
                      icon: option.iosSymbol == null
                          ? null
                          : CNSymbol(option.iosSymbol!),
                    ),
                ],
                onChanged: onChanged == null
                    ? null
                    : (index) {
                        if (!state.mounted ||
                            !state.widget.enabled ||
                            index < 0 ||
                            index >= options.length) {
                          return;
                        }
                        final option = options[index];
                        if (!option.enabled) return;
                        state.didChange(option.value);
                        onChanged?.call(option.value);
                      },
                tint: context.conduitTheme.inputText,
                height: 44,
                // VoiceOver reads the field name, then the selected label.
                semanticLabel: fieldName == null || fieldName.isEmpty
                    ? null
                    : fieldName,
              ),
            ),
          );
        }
        return Builder(
          builder: (anchorContext) => Semantics(
            button: true,
            enabled: onChanged != null,
            // The field's name, as the native control is given it.
            label: semanticLabel,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppBorderRadius.standard),
              onTap: onChanged == null
                  ? null
                  : () => _showNative(anchorContext, state),
              child: InputDecorator(
                decoration: effectiveDecoration,
                isEmpty: selected == null,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        selected?.label ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            textStyle ??
                            Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: selected == null
                                  ? context.conduitTheme.textTertiary
                                  : context.conduitTheme.inputText,
                            ),
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Icon(
                      CupertinoIcons.chevron_down,
                      color: context.conduitTheme.iconSecondary,
                      size: IconSize.small,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showNative(
    BuildContext context,
    FormFieldState<T> state,
  ) async {
    final selection = await showAdaptiveNativeSingleChoice<T>(
      context: context,
      // What the field shows: a choice its parent has not rebuilt with yet.
      value: state.value,
      options: options,
      title: nativeTitle ?? decoration.labelText,
      cancelLabel:
          cancelLabel ?? MaterialLocalizations.of(context).cancelButtonLabel,
    );
    if (!context.mounted || !state.mounted) return;
    // As for the pop-up button: a field disabled while the sheet was open
    // takes no choice.
    if (selection == null || !state.widget.enabled) return;
    state.didChange(selection.value);
    onChanged?.call(selection.value);
  }
}

/// Typed single-choice trigger with native iOS presentation and an anchored
/// adaptive menu elsewhere. The caller owns the trigger's visual treatment.
class AdaptiveSingleChoiceTrigger<T> extends StatelessWidget {
  const AdaptiveSingleChoiceTrigger({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.child,
    this.nativeTitle,
    this.cancelLabel,
    this.semanticLabel,
    this.fallbackReplacement,
  });

  final T? value;
  final List<AdaptiveDropdownOption<T>> options;
  final ValueChanged<T> onChanged;
  final Widget child;
  final String? nativeTitle;
  final String? cancelLabel;
  final String? semanticLabel;
  final Widget? fallbackReplacement;

  @override
  Widget build(BuildContext context) {
    if (PlatformInfo.isIOS) {
      return Builder(
        builder: (anchorContext) => Semantics(
          button: true,
          label: semanticLabel,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showNative(anchorContext),
            child: child,
          ),
        ),
      );
    }

    final menu = AdaptivePopupMenuButton.widget<T>(
      child: child,
      items: [
        for (final option in options)
          AdaptivePopupMenuItem<T>(
            value: option.value,
            label: option.label,
            checked: option.value == value,
            enabled: option.enabled,
          ),
      ],
      onSelected: (_, entry) {
        for (final option in options) {
          if (option.value == entry.value) {
            onChanged(option.value);
            return;
          }
        }
      },
    );
    final accessibleMenu = semanticLabel == null
        ? menu
        : Semantics(button: true, label: semanticLabel, child: menu);
    final replacement = fallbackReplacement;
    return replacement == null
        ? accessibleMenu
        : ThemedSheets.hideNativeChromeWhileCovered(
            replacement: replacement,
            child: accessibleMenu,
          );
  }

  Future<void> _showNative(BuildContext context) async {
    final selection = await showAdaptiveNativeSingleChoice<T>(
      context: context,
      value: value,
      options: options,
      title: nativeTitle,
      cancelLabel:
          cancelLabel ?? MaterialLocalizations.of(context).cancelButtonLabel,
    );
    if (!context.mounted) return;
    if (selection != null) onChanged(selection.value);
  }
}

/// A completed native selection. The wrapper distinguishes choosing a nullable
/// value from dismissing the native picker, which returns no result.
@immutable
class AdaptiveSingleChoiceResult<T> {
  const AdaptiveSingleChoiceResult(this.value);

  final T value;
}

Future<AdaptiveSingleChoiceResult<T>?> showAdaptiveNativeSingleChoice<T>({
  required BuildContext context,
  required T? value,
  required List<AdaptiveDropdownOption<T>> options,
  String? title,
  String? cancelLabel,
}) async {
  final selected = await IosNativeDropdownBridge.instance.showFromContext(
    context: context,
    title: title,
    cancelLabel:
        cancelLabel ?? MaterialLocalizations.of(context).cancelButtonLabel,
    options: [
      for (final (index, option) in options.indexed)
        IosNativeDropdownOption(
          id: '$index',
          label: option.label,
          subtitle: option.subtitle,
          enabled: option.enabled,
          sfSymbol: option.value == value ? 'checkmark' : option.iosSymbol,
        ),
    ],
  );
  final result = adaptiveSingleChoiceResultForId(
    selectedId: selected,
    options: options,
  );
  return result;
}

/// Resolves the index-based native response without conflating a selected
/// nullable value with dismissal.
AdaptiveSingleChoiceResult<T>? adaptiveSingleChoiceResultForId<T>({
  required String? selectedId,
  required List<AdaptiveDropdownOption<T>> options,
}) {
  final index = int.tryParse(selectedId ?? '');
  if (index == null || index < 0 || index >= options.length) return null;
  final option = options[index];
  return option.enabled ? AdaptiveSingleChoiceResult(option.value) : null;
}
