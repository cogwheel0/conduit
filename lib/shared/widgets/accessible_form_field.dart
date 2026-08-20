part of 'conduit_components.dart';

/// Enhanced form field with better accessibility and validation
class AccessibleFormField extends StatelessWidget {
  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final bool obscureText;
  final bool enabled;
  final bool readOnly;
  final String? errorText;
  final int? maxLines;
  final int? minLines;
  final Widget? suffixIcon;
  final Widget? prefixIcon;
  final TextInputType? keyboardType;
  final bool autofocus;
  final String? semanticLabel;
  final String? Function(String?)? validator;
  final bool isRequired;
  final bool isCompact;
  final Iterable<String>? autofillHints;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final bool autocorrect;
  final TextStyle? style;
  final bool iosSettingsRow;
  final int iosLabelFlex;

  const AccessibleFormField({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.obscureText = false,
    this.enabled = true,
    this.readOnly = false,
    this.errorText,
    this.maxLines = 1,
    this.minLines,
    this.suffixIcon,
    this.prefixIcon,
    this.keyboardType,
    this.autofocus = false,
    this.semanticLabel,
    this.validator,
    this.isRequired = false,
    this.isCompact = false,
    this.autofillHints,
    this.focusNode,
    this.textInputAction,
    this.autocorrect = true,
    this.style,
    this.iosSettingsRow = false,
    this.iosLabelFlex = 4,
  }) : assert(iosLabelFlex > 0 && iosLabelFlex < 10);

  @override
  Widget build(BuildContext context) {
    final hasExternalError = errorText?.trim().isNotEmpty ?? false;
    if (PlatformInfo.isIOS && iosSettingsRow && label != null) {
      return _buildIosSettingsRow(context, hasExternalError);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Wrap(
            spacing: Spacing.textSpacing,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.standard.copyWith(
                  fontWeight: FontWeight.w500,
                  color: context.conduitTheme.textPrimary,
                ),
              ),
              if (isRequired)
                Text(
                  '*',
                  style: AppTypography.standard.copyWith(
                    color: context.conduitTheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          SizedBox(height: isCompact ? Spacing.xs : Spacing.sm),
        ],
        Semantics(
          label: semanticLabel ?? label ?? _fallbackLabel(context),
          textField: true,
          child: _buildInput(
            context,
            suffix: suffixIcon,
            inputStyle:
                style ??
                AppTypography.standard.copyWith(
                  color: context.conduitTheme.textPrimary,
                ),
            inputPadding: EdgeInsets.symmetric(
              horizontal: isCompact ? Spacing.md : Spacing.inputPadding,
              vertical: isCompact ? Spacing.sm : Spacing.md,
            ),
            materialDecoration: InputDecoration(
              hintText: hint,
              hintStyle: AppTypography.inputHintStyle.copyWith(
                color: context.conduitTheme.inputPlaceholder,
              ),
              filled: true,
              fillColor: context.conduitTheme.inputBackground,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.input),
                borderSide: BorderSide(
                  color: context.conduitTheme.inputBorder,
                  width: BorderWidth.standard,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.input),
                borderSide: BorderSide(
                  color: context.conduitTheme.inputBorder,
                  width: BorderWidth.standard,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.input),
                borderSide: BorderSide(
                  color: context.conduitTheme.buttonPrimary,
                  width: BorderWidth.thick,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.input),
                borderSide: BorderSide(
                  color: context.conduitTheme.error,
                  width: BorderWidth.standard,
                ),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.input),
                borderSide: BorderSide(
                  color: context.conduitTheme.error,
                  width: BorderWidth.thick,
                ),
              ),
              contentPadding: EdgeInsets.symmetric(
                horizontal: isCompact ? Spacing.md : Spacing.inputPadding,
                vertical: isCompact ? Spacing.sm : Spacing.md,
              ),
              suffixIcon: suffixIcon,
              prefixIcon: prefixIcon,
              errorText: context.usesCupertinoChrome ? null : errorText,
              errorStyle: AppTypography.small.copyWith(
                color: context.conduitTheme.error,
              ),
            ),
            cupertinoBoxDecoration: BoxDecoration(
              color: enabled
                  ? CupertinoColors.tertiarySystemFill.resolveFrom(context)
                  : CupertinoColors.quaternarySystemFill.resolveFrom(context),
              border: hasExternalError
                  ? Border.all(
                      color: CupertinoColors.systemRed.resolveFrom(context),
                      width: BorderWidth.standard,
                    )
                  : null,
              borderRadius: BorderRadius.circular(AppBorderRadius.input),
            ),
          ),
        ),
        if (context.usesCupertinoChrome && hasExternalError)
          Semantics(
            liveRegion: true,
            label: errorText,
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.only(
                  top: Spacing.xs,
                  left: Spacing.inputPadding,
                ),
                child: Text(
                  errorText!,
                  style: AppTypography.small.copyWith(
                    color: context.conduitTheme.error,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildIosSettingsRow(BuildContext context, bool hasExternalError) {
    final theme = context.conduitTheme;
    final resolvedLabel = semanticLabel ?? label!;
    final labelStyle = AppTypography.bodyMediumStyle.copyWith(
      color: theme.textPrimary,
      fontWeight: FontWeight.w400,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TouchTarget.comfortable),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: Row(
              children: [
                Expanded(
                  flex: iosLabelFlex,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          label!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: labelStyle,
                        ),
                      ),
                      // In an iOS settings list, required fields are conveyed
                      // by validation and Save availability. Red asterisks make
                      // the row read like a web form and add visual noise.
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  flex: 10 - iosLabelFlex,
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          label: resolvedLabel,
                          textField: true,
                          child: _buildInput(
                            context,
                            textAlign: TextAlign.end,
                            inputStyle:
                                style ??
                                AppTypography.bodyMediumStyle.copyWith(
                                  color: theme.textPrimary,
                                ),
                            inputPadding: EdgeInsetsDirectional.only(
                              end: suffixIcon == null ? 0 : Spacing.sm,
                              top: Spacing.md,
                              bottom: Spacing.md,
                            ),
                            materialDecoration: const InputDecoration(
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                            ),
                            cupertinoBoxDecoration: const BoxDecoration(
                              color: Colors.transparent,
                            ),
                          ),
                        ),
                      ),
                      if (suffixIcon != null)
                        SizedBox(
                          width: IconSize.small,
                          height: TouchTarget.minimum,
                          child: OverflowBox(
                            minWidth: TouchTarget.minimum,
                            maxWidth: TouchTarget.minimum,
                            minHeight: TouchTarget.minimum,
                            maxHeight: TouchTarget.minimum,
                            child: suffixIcon,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasExternalError)
          Semantics(
            liveRegion: true,
            label: errorText,
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.md,
                  0,
                  Spacing.md,
                  Spacing.sm,
                ),
                child: Text(
                  errorText!,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.error,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _fallbackLabel(BuildContext context) =>
      AppLocalizations.of(context)?.inputField ?? 'Input field';

  Widget _buildInput(
    BuildContext context, {
    required EdgeInsetsGeometry inputPadding,
    required InputDecoration materialDecoration,
    required BoxDecoration cupertinoBoxDecoration,
    required TextStyle inputStyle,
    TextAlign textAlign = TextAlign.start,
    Widget? suffix,
  }) {
    return AdaptiveTextFormField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onTap: onTap,
      onSubmitted: onSubmitted,
      obscureText: obscureText,
      enabled: enabled,
      readOnly: readOnly,
      maxLines: maxLines,
      minLines: minLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autocorrect: autocorrect,
      autofocus: autofocus,
      validator: validator != null
          ? (value) => validator!(value ?? controller?.text)
          : null,
      autofillHints: autofillHints?.toList(),
      placeholder: hint,
      prefixIcon: prefixIcon,
      suffixIcon: suffix,
      textAlign: textAlign,
      style: inputStyle,
      padding: inputPadding,
      decoration: materialDecoration,
      cupertinoDecoration: cupertinoBoxDecoration,
    );
  }
}
