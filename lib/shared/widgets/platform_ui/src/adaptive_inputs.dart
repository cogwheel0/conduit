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
      final effectiveDecoration = (decoration ?? const InputDecoration())
          .copyWith(
            hintText: decoration?.hintText ?? placeholder,
            prefix: prefix ?? decoration?.prefix,
            suffix: suffix ?? decoration?.suffix,
            prefixIcon: prefixIcon ?? decoration?.prefixIcon,
            suffixIcon: suffixIcon ?? decoration?.suffixIcon,
            contentPadding: padding ?? decoration?.contentPadding,
          );
      return TextField(
        controller: controller,
        focusNode: focusNode,
        decoration: effectiveDecoration,
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
      prefix: prefix ?? _paddedIcon(prefixIcon),
      suffix: suffix ?? _paddedIcon(suffixIcon),
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

  static Widget? _paddedIcon(Widget? icon) {
    if (icon == null) return null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: icon,
    );
  }
}

class AdaptiveTextFormField extends StatefulWidget {
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
  State<AdaptiveTextFormField> createState() => _AdaptiveTextFormFieldState();
}

class _AdaptiveTextFormFieldState extends State<AdaptiveTextFormField> {
  final _formFieldKey = GlobalKey<FormFieldState<String>>();
  TextEditingController? _internalController;
  late String _initialValue;

  TextEditingController get _effectiveController =>
      widget.controller ?? _internalController!;

  @override
  void initState() {
    super.initState();
    _initialValue = widget.controller?.text ?? widget.initialValue ?? '';
    if (widget.controller == null) {
      _internalController = TextEditingController(text: _initialValue);
    }
    _effectiveController.addListener(_syncControllerValue);
  }

  @override
  void didUpdateWidget(covariant AdaptiveTextFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) {
      if (widget.controller == null &&
          oldWidget.initialValue != widget.initialValue) {
        _initialValue = widget.initialValue ?? '';
      }
      return;
    }

    final previousController = oldWidget.controller ?? _internalController!;
    previousController.removeListener(_syncControllerValue);
    final currentValue = _formFieldKey.currentState?.value ?? '';
    if (widget.controller == null) {
      _internalController = TextEditingController(text: currentValue);
      _initialValue = widget.initialValue ?? currentValue;
    } else {
      _internalController?.dispose();
      _internalController = null;
      _initialValue = widget.controller!.text;
    }
    _effectiveController.addListener(_syncControllerValue);
    _syncControllerValue();
  }

  @override
  void dispose() {
    _effectiveController.removeListener(_syncControllerValue);
    _internalController?.dispose();
    super.dispose();
  }

  void _syncControllerValue() {
    final value = _effectiveController.text;
    if (_formFieldKey.currentState?.value == value) return;
    _formFieldKey.currentState?.didChange(value);
  }

  void _resetController() {
    _effectiveController.value = TextEditingValue(
      text: _initialValue,
      selection: TextSelection.collapsed(offset: _initialValue.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.isIOS) {
      return TextFormField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        initialValue: widget.controller == null ? widget.initialValue : null,
        decoration: (widget.decoration ?? const InputDecoration()).copyWith(
          hintText: widget.decoration?.hintText ?? widget.placeholder,
          prefix: widget.prefix ?? widget.decoration?.prefix,
          suffix: widget.suffix ?? widget.decoration?.suffix,
          prefixIcon: widget.prefixIcon ?? widget.decoration?.prefixIcon,
          suffixIcon: widget.suffixIcon ?? widget.decoration?.suffixIcon,
          contentPadding: widget.padding ?? widget.decoration?.contentPadding,
        ),
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        textCapitalization: widget.textCapitalization,
        style: widget.style,
        textAlign: widget.textAlign,
        maxLines: widget.maxLines,
        minLines: widget.minLines,
        maxLength: widget.maxLength,
        obscureText: widget.obscureText,
        autocorrect: widget.autocorrect,
        autofocus: widget.autofocus,
        enabled: widget.enabled,
        readOnly: widget.readOnly,
        onChanged: widget.onChanged,
        onFieldSubmitted: widget.onSubmitted,
        onTap: widget.onTap,
        onSaved: widget.onSaved,
        validator: widget.validator,
        inputFormatters: widget.inputFormatters,
        autovalidateMode: widget.autovalidateMode,
        onTapOutside: widget.onTapOutside,
        autofillHints: widget.autofillHints,
      );
    }

    return FormField<String>(
      key: _formFieldKey,
      initialValue: _initialValue,
      onSaved: widget.onSaved,
      onReset: _resetController,
      validator: widget.validator,
      autovalidateMode: widget.autovalidateMode ?? AutovalidateMode.disabled,
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CupertinoTextField(
            controller: _effectiveController,
            focusNode: widget.focusNode,
            placeholder: widget.placeholder ?? widget.decoration?.hintText,
            keyboardType: widget.keyboardType,
            textInputAction: widget.textInputAction,
            textCapitalization: widget.textCapitalization,
            style: widget.style,
            textAlign: widget.textAlign,
            maxLines: widget.maxLines,
            minLines: widget.minLines,
            maxLength: widget.maxLength,
            obscureText: widget.obscureText,
            autocorrect: widget.autocorrect,
            autofocus: widget.autofocus,
            enabled: widget.enabled,
            readOnly: widget.readOnly,
            prefix:
                widget.prefix ??
                AdaptiveTextField._paddedIcon(widget.prefixIcon),
            suffix:
                widget.suffix ??
                AdaptiveTextField._paddedIcon(widget.suffixIcon),
            onChanged: (value) {
              field.didChange(value);
              widget.onChanged?.call(value);
            },
            onSubmitted: widget.onSubmitted,
            onTap: widget.onTap,
            inputFormatters: widget.inputFormatters,
            padding: widget.padding ?? const EdgeInsets.all(12),
            decoration:
                widget.cupertinoDecoration ??
                BoxDecoration(
                  color: CupertinoColors.tertiarySystemBackground.resolveFrom(
                    context,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
            onTapOutside: widget.onTapOutside,
            autofillHints: widget.autofillHints,
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
