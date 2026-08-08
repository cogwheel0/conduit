import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform_ui_capabilities.dart';

class AdaptiveTextField extends StatelessWidget {
  const AdaptiveTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.textAlign = TextAlign.start,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.obscureText = false,
    this.autocorrect = true,
    this.autofocus = false,
    this.enabled = true,
    this.readOnly = false,
    this.prefix,
    this.suffix,
    this.prefixIcon,
    this.suffixIcon,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.inputFormatters,
    this.padding,
    this.decoration,
    this.cupertinoDecoration,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? placeholder;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextStyle? style;
  final TextAlign textAlign;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  final bool obscureText;
  final bool autocorrect;
  final bool autofocus;
  final bool enabled;
  final bool readOnly;
  final Widget? prefix;
  final Widget? suffix;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final List<TextInputFormatter>? inputFormatters;
  final EdgeInsetsGeometry? padding;
  final InputDecoration? decoration;
  final BoxDecoration? cupertinoDecoration;

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.isIOS) {
      return TextField(
        controller: controller,
        focusNode: focusNode,
        decoration: decoration ?? InputDecoration(hintText: placeholder),
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        minLines: minLines,
        maxLength: maxLength,
        obscureText: obscureText,
        autocorrect: autocorrect,
        autofocus: autofocus,
        enabled: enabled,
        readOnly: readOnly,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        onTap: onTap,
        inputFormatters: inputFormatters,
      );
    }
    return CupertinoTextField(
      controller: controller,
      focusNode: focusNode,
      placeholder: placeholder ?? decoration?.hintText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      minLines: minLines,
      maxLength: maxLength,
      obscureText: obscureText,
      autocorrect: autocorrect,
      autofocus: autofocus,
      enabled: enabled,
      readOnly: readOnly,
      prefix: prefix ?? _paddedIcon(prefixIcon, leading: true),
      suffix: suffix ?? _paddedIcon(suffixIcon, leading: false),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      onTap: onTap,
      inputFormatters: inputFormatters,
      padding: padding ?? const EdgeInsets.all(12),
      decoration:
          cupertinoDecoration ??
          BoxDecoration(
            color: CupertinoColors.tertiarySystemBackground.resolveFrom(
              context,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
    );
  }

  static Widget? _paddedIcon(Widget? icon, {required bool leading}) {
    if (icon == null) return null;
    return Padding(
      padding: EdgeInsets.only(left: leading ? 6 : 0, right: leading ? 6 : 6),
      child: icon,
    );
  }
}

class AdaptiveTextFormField extends StatelessWidget {
  const AdaptiveTextFormField({
    super.key,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.initialValue,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.textAlign = TextAlign.start,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.obscureText = false,
    this.autocorrect = true,
    this.autofocus = false,
    this.enabled = true,
    this.readOnly = false,
    this.prefix,
    this.suffix,
    this.prefixIcon,
    this.suffixIcon,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.onSaved,
    this.validator,
    this.inputFormatters,
    this.padding,
    this.decoration,
    this.cupertinoDecoration,
    this.autovalidateMode,
    this.onTapOutside,
    this.autofillHints,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? placeholder;
  final String? initialValue;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextStyle? style;
  final TextAlign textAlign;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  final bool obscureText;
  final bool autocorrect;
  final bool autofocus;
  final bool enabled;
  final bool readOnly;
  final Widget? prefix;
  final Widget? suffix;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final FormFieldSetter<String>? onSaved;
  final FormFieldValidator<String>? validator;
  final List<TextInputFormatter>? inputFormatters;
  final EdgeInsetsGeometry? padding;
  final InputDecoration? decoration;
  final BoxDecoration? cupertinoDecoration;
  final AutovalidateMode? autovalidateMode;
  final TapRegionCallback? onTapOutside;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.isIOS) {
      return TextFormField(
        controller: controller,
        focusNode: focusNode,
        initialValue: controller == null ? initialValue : null,
        decoration: decoration ?? InputDecoration(hintText: placeholder),
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        minLines: minLines,
        maxLength: maxLength,
        obscureText: obscureText,
        autocorrect: autocorrect,
        autofocus: autofocus,
        enabled: enabled,
        readOnly: readOnly,
        onChanged: onChanged,
        onFieldSubmitted: onSubmitted,
        onTap: onTap,
        onSaved: onSaved,
        validator: validator,
        inputFormatters: inputFormatters,
        autovalidateMode: autovalidateMode,
        onTapOutside: onTapOutside,
        autofillHints: autofillHints,
      );
    }

    return FormField<String>(
      initialValue: controller == null ? initialValue ?? '' : null,
      onSaved: onSaved,
      validator: validator,
      autovalidateMode: autovalidateMode ?? AutovalidateMode.disabled,
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CupertinoTextField(
            controller: controller,
            focusNode: focusNode,
            placeholder: placeholder ?? decoration?.hintText,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            textCapitalization: textCapitalization,
            style: style,
            textAlign: textAlign,
            maxLines: maxLines,
            minLines: minLines,
            maxLength: maxLength,
            obscureText: obscureText,
            autocorrect: autocorrect,
            autofocus: autofocus,
            enabled: enabled,
            readOnly: readOnly,
            prefix:
                prefix ??
                AdaptiveTextField._paddedIcon(prefixIcon, leading: true),
            suffix:
                suffix ??
                AdaptiveTextField._paddedIcon(suffixIcon, leading: false),
            onChanged: (value) {
              field.didChange(value);
              onChanged?.call(value);
            },
            onSubmitted: onSubmitted,
            onTap: onTap,
            inputFormatters: inputFormatters,
            padding: padding ?? const EdgeInsets.all(12),
            decoration:
                cupertinoDecoration ??
                BoxDecoration(
                  color: CupertinoColors.tertiarySystemBackground.resolveFrom(
                    context,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
            onTapOutside: onTapOutside,
            autofillHints: autofillHints,
          ),
          if (field.hasError)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 6),
              child: Text(
                field.errorText ?? '',
                style: const TextStyle(
                  color: CupertinoColors.systemRed,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
