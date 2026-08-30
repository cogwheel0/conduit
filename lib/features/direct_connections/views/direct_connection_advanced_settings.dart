part of 'direct_connection_editor_sections.dart';

const _manualModelsFieldKey = ValueKey<String>('direct-manual-models-field');

Future<void> showDirectConnectionAdvancedSettings(
  BuildContext context,
  DirectConnectionEditorForm form,
) {
  form.setShowAdvancedSettings(true);
  return Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => DirectConnectionAdvancedSettingsPage(form: form),
    ),
  );
}

final class DirectConnectionAdvancedSettingsPage extends StatelessWidget {
  const DirectConnectionAdvancedSettingsPage({super.key, required this.form});

  final DirectConnectionEditorForm form;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AnimatedBuilder(
      animation: form,
      builder: (context, _) => UtilityPageScaffold.settings(
        title: l10n.advancedSettings,
        backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
          context,
        ),
        contentPadding: const EdgeInsets.fromLTRB(
          Spacing.screenPadding,
          Spacing.sm,
          Spacing.screenPadding,
          Spacing.lg,
        ),
        children: [_NativeAdvancedSettingsContent(form: form)],
      ),
    );
  }
}

AccessibleFormField _advancedTextField({
  required Key key,
  required String label,
  required String hint,
  required TextEditingController controller,
  required bool native,
  String? errorText,
  FocusNode? focusNode,
  ValueChanged<String>? onSubmitted,
  int? minLines = 1,
  int? maxLines = 1,
  TextInputType? keyboardType,
  TextInputAction? textInputAction = TextInputAction.next,
}) => AccessibleFormField(
  key: key,
  label: label,
  hint: hint,
  controller: controller,
  errorText: errorText,
  focusNode: focusNode,
  onSubmitted: onSubmitted,
  minLines: minLines,
  maxLines: maxLines,
  keyboardType: keyboardType,
  textInputAction: textInputAction,
  autocorrect: false,
  iosSettingsRow: native,
);

Widget _headerNameField(
  DirectConnectionEditorForm form,
  AppLocalizations l10n, {
  required bool native,
}) => _advancedTextField(
  key: const ValueKey<String>('direct-custom-header-name-field'),
  label: l10n.headerName,
  hint: 'X-Custom-Header',
  controller: form.headerName,
  errorText: directHeaderValidationMessage(l10n, form.headerError),
  onSubmitted: (_) => form.headerValueFocusNode.requestFocus(),
  native: native,
);

Widget _headerValueField(
  DirectConnectionEditorForm form,
  AppLocalizations l10n, {
  required bool native,
}) => _advancedTextField(
  key: const ValueKey<String>('direct-custom-header-value-field'),
  label: l10n.headerValue,
  hint: l10n.headerValueHint,
  controller: form.headerValue,
  focusNode: form.headerValueFocusNode,
  textInputAction: TextInputAction.done,
  onSubmitted: (_) {
    if (form.canAddCustomHeader) form.addCustomHeader();
  },
  native: native,
);

Widget _modelPrefixField(
  DirectConnectionEditorForm form,
  AppLocalizations l10n, {
  required bool native,
}) => _advancedTextField(
  key: const ValueKey<String>('direct-model-prefix-field'),
  label: l10n.directModelIdPrefix,
  hint: 'studio',
  controller: form.modelIdPrefix,
  native: native,
);

Widget _modelTagsField(
  DirectConnectionEditorForm form,
  AppLocalizations l10n, {
  required bool native,
}) => _advancedTextField(
  key: const ValueKey<String>('direct-model-tags-field'),
  label: l10n.directModelTags,
  hint: 'local, private',
  controller: form.tags,
  native: native,
);

Widget _apiVersionField(
  DirectConnectionEditorForm form,
  AppLocalizations l10n, {
  required bool native,
}) => _advancedTextField(
  key: const ValueKey<String>('direct-api-version-field'),
  label: l10n.directApiVersion,
  hint: '2024-10-21',
  controller: form.apiVersion,
  native: native,
);

Widget _manualModelsField(
  DirectConnectionEditorForm form,
  AppLocalizations l10n,
) => _advancedTextField(
  key: _manualModelsFieldKey,
  label: l10n.directManualModelIds,
  hint: 'model-a\nmodel-b',
  controller: form.models,
  minLines: 3,
  maxLines: 8,
  keyboardType: TextInputType.multiline,
  textInputAction: TextInputAction.newline,
  native: false,
);

final class _NativeAdvancedSettingsContent extends StatelessWidget {
  const _NativeAdvancedSettingsContent({required this.form});

  final DirectConnectionEditorForm form;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!form.isOllama) ...[
          _NativeCompletionApiGroup(form: form),
          const SizedBox(height: Spacing.md),
        ],
        _NativeCustomHeadersGroup(form: form),
        const SizedBox(height: Spacing.md),
        InsetGroupedList(
          useNativeSurface: true,
          footer:
              '${l10n.directModelIdPrefixDescription}\n\n${l10n.directModelTagsDescription}',
          children: [
            _modelPrefixField(form, l10n, native: true),
            _modelTagsField(form, l10n, native: true),
          ],
        ),
        const SizedBox(height: Spacing.md),
        InsetGroupedSection(
          title: l10n.directManualModelIds,
          footer: l10n.directManualModelIdsDescription,
          useNativeSurface: true,
          padding: EdgeInsets.zero,
          child: Semantics(
            label: l10n.directManualModelIds,
            textField: true,
            child: CupertinoTextField(
              key: _manualModelsFieldKey,
              controller: form.models,
              placeholder: 'model-a\nmodel-b',
              minLines: 3,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              autocorrect: false,
              padding: const EdgeInsets.all(Spacing.md),
              style: AppTypography.bodyMediumStyle.copyWith(
                color: context.conduitTheme.textPrimary,
              ),
              placeholderStyle: AppTypography.bodyMediumStyle.copyWith(
                color: CupertinoColors.placeholderText.resolveFrom(context),
              ),
              decoration: const BoxDecoration(color: Colors.transparent),
            ),
          ),
        ),
      ],
    );
  }
}

final class _NativeCompletionApiGroup extends StatelessWidget {
  const _NativeCompletionApiGroup({required this.form});

  final DirectConnectionEditorForm form;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final options = [
      AdaptiveDropdownOption(
        value: DirectOpenAiApiMode.chatCompletions,
        label: l10n.directChatCompletions,
      ),
      AdaptiveDropdownOption(
        value: DirectOpenAiApiMode.responses,
        label: l10n.directResponses,
      ),
    ];
    final selectedLabel = form.openAiApiMode == DirectOpenAiApiMode.responses
        ? l10n.directResponses
        : l10n.directChatCompletions;
    final description = form.isOpenRouter
        ? l10n.directOpenRouterChatCompletionsDescription
        : form.openAiApiMode == DirectOpenAiApiMode.responses
        ? l10n.directResponsesDescription
        : l10n.directChatCompletionsDescription;

    return InsetGroupedList(
      useNativeSurface: true,
      footer: form.isOpenRouter
          ? description
          : '$description\n\n${l10n.directApiVersionDescription}',
      children: [
        if (form.isOpenRouter)
          UtilityValueRow(
            label: l10n.directCompletionApi,
            value: selectedLabel,
            titleFontWeight: FontWeight.w400,
            valueFontWeight: FontWeight.w400,
          )
        else
          AdaptiveSingleChoiceTrigger<DirectOpenAiApiMode>(
            key: const ValueKey<String>('direct-openai-api-mode-selector'),
            value: form.openAiApiMode,
            options: options,
            onChanged: form.setOpenAiApiMode,
            nativeTitle: l10n.directCompletionApi,
            semanticLabel: '${l10n.directCompletionApi}, $selectedLabel',
            child: UtilityValueRow(
              label: l10n.directCompletionApi,
              value: selectedLabel,
              titleFontWeight: FontWeight.w400,
              valueFontWeight: FontWeight.w400,
              selectable: false,
              showChevron: true,
            ),
          ),
        if (!form.isOpenRouter) _apiVersionField(form, l10n, native: true),
      ],
    );
  }
}

final class _NativeCustomHeadersGroup extends StatelessWidget {
  const _NativeCustomHeadersGroup({required this.form});

  final DirectConnectionEditorForm form;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedList(
      title: l10n.directCustomHeaders,
      footer: l10n.customHeadersDescription,
      useNativeSurface: true,
      children: [
        _headerNameField(form, l10n, native: true),
        _headerValueField(form, l10n, native: true),
        UtilityRow(
          key: const ValueKey<String>('add-direct-custom-header-button'),
          title: l10n.addHeader,
          titleFontWeight: FontWeight.w400,
          foregroundColor: CupertinoColors.activeBlue.resolveFrom(context),
          enabled: form.canAddCustomHeader,
          onTap: form.canAddCustomHeader ? form.addCustomHeader : null,
        ),
        for (final entry in form.customHeaders.entries)
          UtilityRow(
            title: entry.key,
            subtitle: entry.value,
            titleFontWeight: FontWeight.w400,
            preserveTrailingSemantics: true,
            trailing: ConduitIconButton(
              icon: CupertinoIcons.minus_circle,
              tooltip: l10n.removeHeader,
              onPressed: () => form.removeCustomHeader(entry.key),
              backgroundColor: Colors.transparent,
              iconColor: CupertinoColors.systemRed.resolveFrom(context),
              isCompact: true,
            ),
          ),
      ],
    );
  }
}

final class _AdvancedSettingsContent extends StatelessWidget {
  const _AdvancedSettingsContent({required this.form});

  final DirectConnectionEditorForm form;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!form.isOllama) ...[
          _AdvancedApiBehavior(form: form),
          const SizedBox(height: Spacing.xl),
          Divider(height: BorderWidth.thin, color: theme.dividerColor),
          const SizedBox(height: Spacing.lg),
        ],
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.directCustomHeaders,
                    style: theme.bodyMedium?.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    l10n.customHeadersDescription,
                    style: theme.bodySmall?.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (form.customHeaders.isNotEmpty)
              Text(
                '${form.customHeaders.length}',
                style: theme.bodySmall?.copyWith(color: theme.textTertiary),
              ),
          ],
        ),
        const SizedBox(height: Spacing.md),
        _headerNameField(form, l10n, native: false),
        const SizedBox(height: Spacing.md),
        _headerValueField(form, l10n, native: false),
        const SizedBox(height: Spacing.md),
        ConduitButton(
          key: const ValueKey<String>('add-direct-custom-header-button'),
          text: l10n.addHeader,
          isSecondary: true,
          isFullWidth: true,
          onPressed: form.canAddCustomHeader ? form.addCustomHeader : null,
        ),
        if (form.customHeaders.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          for (final entry in form.customHeaders.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xs),
              child: Container(
                padding: const EdgeInsets.only(
                  left: Spacing.md,
                  top: Spacing.sm,
                  bottom: Spacing.sm,
                  right: Spacing.xs,
                ),
                decoration: BoxDecoration(
                  color: theme.surfaceBackground,
                  borderRadius: BorderRadius.circular(AppBorderRadius.small),
                  border: Border.all(
                    color: theme.cardBorder,
                    width: BorderWidth.thin,
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      entry.key,
                      style: theme.bodySmall?.copyWith(
                        color: theme.buttonPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        entry.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.bodySmall?.copyWith(
                          color: theme.textSecondary,
                          fontFamily: AppTypography.monospaceFontFamily,
                        ),
                      ),
                    ),
                    ConduitIconButton(
                      icon: Icons.close_rounded,
                      tooltip: l10n.removeHeader,
                      onPressed: () => form.removeCustomHeader(entry.key),
                      backgroundColor: Colors.transparent,
                      iconColor: theme.textTertiary,
                      isCompact: true,
                    ),
                  ],
                ),
              ),
            ),
        ],
        const SizedBox(height: Spacing.xl),
        _modelPrefixField(form, l10n, native: false),
        const SizedBox(height: Spacing.sm),
        Text(
          l10n.directModelIdPrefixDescription,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.md),
        _modelTagsField(form, l10n, native: false),
        const SizedBox(height: Spacing.sm),
        Text(
          l10n.directModelTagsDescription,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.xl),
        _manualModelsField(form, l10n),
        const SizedBox(height: Spacing.sm),
        Text(
          l10n.directManualModelIdsDescription,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
      ],
    );
  }
}

final class _AdvancedApiBehavior extends StatelessWidget {
  const _AdvancedApiBehavior({required this.form});

  final DirectConnectionEditorForm form;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.directCompletionApi,
          style: theme.bodyMedium?.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        if (form.isOpenRouter)
          Text(
            l10n.directOpenRouterChatCompletionsDescription,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          )
        else ...[
          AdaptiveSegmentedSelector<DirectOpenAiApiMode>(
            key: const ValueKey<String>('direct-openai-api-mode-selector'),
            value: form.openAiApiMode,
            showIcons: false,
            onChanged: form.setOpenAiApiMode,
            options: [
              (
                value: DirectOpenAiApiMode.chatCompletions,
                label: l10n.directChatCompletions,
                cupertinoIcon: CupertinoIcons.text_bubble,
                materialIcon: Icons.chat_bubble_outline,
                enabled: true,
              ),
              (
                value: DirectOpenAiApiMode.responses,
                label: l10n.directResponses,
                cupertinoIcon: CupertinoIcons.sparkles,
                materialIcon: Icons.auto_awesome_outlined,
                enabled: true,
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            form.openAiApiMode == DirectOpenAiApiMode.responses
                ? l10n.directResponsesDescription
                : l10n.directChatCompletionsDescription,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          const SizedBox(height: Spacing.md),
          _apiVersionField(form, l10n, native: false),
          const SizedBox(height: Spacing.sm),
          Text(
            l10n.directApiVersionDescription,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

final class _ProviderIcon extends StatelessWidget {
  const _ProviderIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: theme.buttonPrimary.withValues(alpha: Alpha.subtle),
        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: IconSize.small, color: theme.buttonPrimary),
    );
  }
}

String? directDraftValidationMessage(
  AppLocalizations l10n,
  DirectDraftValidationIssue? issue,
) => switch (issue) {
  DirectDraftValidationIssue.nameRequired => l10n.directConnectionNameRequired,
  DirectDraftValidationIssue.invalidUrl => l10n.directConnectionUrlInvalid,
  DirectDraftValidationIssue.invalidOpenRouterUrl =>
    l10n.directOpenRouterUrlInvalid,
  DirectDraftValidationIssue.invalidOrcaRouterUrl =>
    l10n.directOrcaRouterUrlInvalid,
  DirectDraftValidationIssue.credentialsReentryRequired =>
    l10n.directConnectionCredentialsReentryRequired,
  DirectDraftValidationIssue.apiKeyRequired =>
    l10n.directConnectionApiKeyRequired,
  DirectDraftValidationIssue.unsupportedAuthentication =>
    l10n.openWebUiDirectConnectionUnsupportedAuth,
  null => null,
};

String? directHeaderValidationMessage(
  AppLocalizations l10n,
  DirectHeaderValidationError? error,
) => switch (error?.issue) {
  DirectHeaderValidationIssue.nameRequired =>
    l10n.directConnectionHeaderNameRequired,
  DirectHeaderValidationIssue.invalidName => l10n.headerNameInvalidChars,
  DirectHeaderValidationIssue.reservedName => l10n.headerNameReserved(
    error!.headerName!,
  ),
  DirectHeaderValidationIssue.duplicateName => l10n.headerAlreadyExists(
    error!.headerName!,
  ),
  DirectHeaderValidationIssue.invalidValue => l10n.headerValueInvalidChars,
  null => null,
};
