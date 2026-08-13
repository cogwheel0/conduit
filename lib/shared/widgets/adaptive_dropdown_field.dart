import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/services/ios_native_dropdown_bridge.dart';
import '../theme/theme_extensions.dart';
import 'platform_ui/platform_ui.dart';

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

/// Form-aware single-choice field that uses the native iOS dropdown bridge
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
    this.cancelLabel,
    this.isExpanded = true,
  });

  final T value;
  final List<AdaptiveDropdownOption<T>> options;
  final ValueChanged<T>? onChanged;
  final InputDecoration decoration;
  final TextStyle? textStyle;
  final FormFieldValidator<T>? validator;
  final String? nativeTitle;
  final String? cancelLabel;
  final bool isExpanded;

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
                if (next != null || options.any((item) => item.value == null)) {
                  onChanged!(next as T);
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
        return Builder(
          builder: (anchorContext) => Semantics(
            button: true,
            enabled: onChanged != null,
            label: [
              if (effectiveDecoration.labelText != null)
                effectiveDecoration.labelText!,
              if (selected != null) selected.label,
            ].join(', '),
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
                        selected?.label ?? effectiveDecoration.hintText ?? '',
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
    final selected = await IosNativeDropdownBridge.instance.showFromContext(
      context: context,
      title: nativeTitle ?? decoration.labelText,
      cancelLabel:
          cancelLabel ?? MaterialLocalizations.of(context).cancelButtonLabel,
      options: [
        for (final (index, option) in options.indexed)
          IosNativeDropdownOption(
            id: '$index',
            label: option.label,
            subtitle: option.subtitle,
            enabled: option.enabled,
            sfSymbol: option.value == state.value
                ? 'checkmark'
                : option.iosSymbol,
          ),
      ],
    );
    final index = int.tryParse(selected ?? '');
    if (index == null || index < 0 || index >= options.length) return;
    final option = options[index];
    if (!option.enabled) return;
    state.didChange(option.value);
    onChanged?.call(option.value);
  }
}
