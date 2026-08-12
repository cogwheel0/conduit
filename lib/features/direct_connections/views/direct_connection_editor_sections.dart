import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../profile/widgets/adaptive_segmented_selector.dart';
import '../controllers/direct_connection_editor_draft.dart';
import '../controllers/direct_connection_editor_form.dart';
import '../controllers/direct_custom_headers_controller.dart';
import '../models/direct_connection_profile.dart';

final class DirectConnectionAvailabilitySection extends StatelessWidget {
  const DirectConnectionAvailabilitySection({super.key, required this.form});

  final DirectConnectionEditorForm form;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      title: l10n.enabledLabel,
      child: InkWell(
        onTap: () => form.setEnabled(!form.enabled),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.enabledLabel,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    l10n.directConnectionEnabledSubtitle,
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.md),
            AdaptiveSwitch(value: form.enabled, onChanged: form.setEnabled),
          ],
        ),
      ),
    );
  }
}

final class DirectConnectionProviderSection extends StatelessWidget {
  const DirectConnectionProviderSection({
    super.key,
    required this.form,
    this.flat = false,
  });

  final DirectConnectionEditorForm form;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    if (!form.policy.editsProvider) {
      return InsetGroupedSection(
        title: l10n.directProvider,
        flat: flat,
        child: Row(
          children: [
            _ProviderIcon(
              icon: context.usesCupertinoChrome
                  ? CupertinoIcons.cloud
                  : Icons.cloud_outlined,
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.openAICompatible,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    l10n.openWebUiDirectConnectionProviderDescription,
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    void select(String value) => form.selectProviderPreset(
      value,
      ollamaDefaultName: l10n.ollamaCloudDefaultName,
      openRouterDefaultName: l10n.openRouterProviderName,
    );

    return InsetGroupedSection(
      key: const ValueKey<String>('direct-provider-preset-selector'),
      title: l10n.directProvider,
      flat: flat,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Column(
        children: [
          UtilitySelectionRow(
            leading: _ProviderIcon(
              icon: context.usesCupertinoChrome
                  ? CupertinoIcons.chevron_left_slash_chevron_right
                  : Icons.api_rounded,
            ),
            title: l10n.openAICompatible,
            subtitle: null,
            selected: form.providerPreset == kOpenAiCompatibleAdapterKey,
            showDivider: true,
            onTap: () => select(kOpenAiCompatibleAdapterKey),
          ),
          UtilitySelectionRow(
            leading: _ProviderIcon(
              icon: context.usesCupertinoChrome
                  ? CupertinoIcons.compass
                  : Icons.explore_outlined,
            ),
            title: l10n.openRouterProviderName,
            subtitle: null,
            selected: form.providerPreset == kOpenRouterProviderPreset,
            showDivider: true,
            onTap: () => select(kOpenRouterProviderPreset),
          ),
          UtilitySelectionRow(
            leading: _ProviderIcon(
              icon: context.usesCupertinoChrome
                  ? CupertinoIcons.desktopcomputer
                  : Icons.computer_outlined,
            ),
            title: l10n.ollama,
            subtitle: null,
            selected: form.providerPreset == kOllamaAdapterKey,
            onTap: () => select(kOllamaAdapterKey),
          ),
        ],
      ),
    );
  }
}

final class DirectConnectionDetailsSection extends StatelessWidget {
  const DirectConnectionDetailsSection({
    super.key,
    required this.form,
    this.flat = false,
  });

  final DirectConnectionEditorForm form;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final usesCupertinoChrome = context.usesCupertinoChrome;
    final isOllama = form.isOllama;
    final isOpenRouter = form.isOpenRouter;
    return InsetGroupedSection(
      title: l10n.directConnectionDetailsTitle,
      flat: flat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (form.policy.editsName) ...[
            AccessibleFormField(
              key: const ValueKey<String>('direct-connection-name-field'),
              label: l10n.directConnectionName,
              hint: isOllama
                  ? l10n.ollamaCloudDefaultName
                  : isOpenRouter
                  ? l10n.openRouterProviderName
                  : 'My provider',
              controller: form.name,
              errorText: directDraftValidationMessage(l10n, form.errors.name),
              isRequired: true,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: Spacing.md),
          ],
          AccessibleFormField(
            key: const ValueKey<String>('direct-base-url-field'),
            label: l10n.directApiBaseUrl,
            hint: isOllama
                ? l10n.ollamaCloudBaseUrlHint
                : isOpenRouter
                ? kOpenRouterApiBaseUrl
                : 'https://api.openai.com/v1',
            controller: form.baseUrl,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            errorText: directDraftValidationMessage(l10n, form.errors.url),
            isRequired: true,
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            isOllama
                ? l10n.ollamaCloudBaseUrlDescription
                : isOpenRouter
                ? l10n.directOpenRouterBaseUrlDescription
                : l10n.directBaseUrlDescription,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Text(
            l10n.directAuthentication,
            style: AppTypography.bodyMediumStyle.copyWith(
              color: theme.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Material(
            type: MaterialType.transparency,
            child: DropdownButtonFormField<DirectAuthenticationMode>(
              key: ValueKey<String>(
                'direct-authentication-selector-${form.providerPreset}',
              ),
              initialValue: form.authentication,
              isExpanded: true,
              decoration: context.conduitInputStyles.standard(),
              dropdownColor: theme.surfaceBackground,
              items: [
                DropdownMenuItem(
                  value: DirectAuthenticationMode.bearer,
                  child: Text(l10n.bearerToken),
                ),
                if (form.canSelectApiKeyHeader)
                  DropdownMenuItem(
                    value: DirectAuthenticationMode.apiKeyHeader,
                    child: Text(l10n.directApiKeyHeader),
                  ),
                if (form.canSelectNoAuthentication)
                  DropdownMenuItem(
                    value: DirectAuthenticationMode.none,
                    child: Text(l10n.noAuthentication),
                  ),
                if (form.authentication == DirectAuthenticationMode.unsupported)
                  DropdownMenuItem(
                    value: DirectAuthenticationMode.unsupported,
                    enabled: false,
                    child: Text(l10n.directConnectionUnavailableLabel),
                  ),
              ],
              onChanged: (value) {
                if (value != null) form.setAuthentication(value);
              },
            ),
          ),
          if (form.authentication == DirectAuthenticationMode.apiKeyHeader) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              l10n.directApiKeyHeaderDescription,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ],
          if (form.authentication == DirectAuthenticationMode.unsupported) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              l10n.openWebUiDirectConnectionUnsupportedAuth,
              style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
            ),
          ],
          if (form.authentication == DirectAuthenticationMode.bearer ||
              form.authentication == DirectAuthenticationMode.apiKeyHeader) ...[
            const SizedBox(height: Spacing.md),
            AccessibleFormField(
              key: const ValueKey<String>('direct-api-key-field'),
              label: l10n.directApiKey,
              hint: (form.savedProfile?.apiKey ?? '').isNotEmpty
                  ? l10n.directConfiguredReplacePlaceholder
                  : l10n.directApiKeyPlaceholder,
              controller: form.apiKey,
              obscureText: !form.showApiKey,
              errorText: directDraftValidationMessage(l10n, form.errors.apiKey),
              isRequired: form.apiKeyRequired,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              suffixIcon: IconButton(
                tooltip: form.showApiKey
                    ? l10n.hidePassword
                    : l10n.showPassword,
                onPressed: () => form.setShowApiKey(!form.showApiKey),
                icon: Icon(
                  form.showApiKey
                      ? (usesCupertinoChrome
                            ? CupertinoIcons.eye_slash
                            : Icons.visibility_off)
                      : (usesCupertinoChrome
                            ? CupertinoIcons.eye
                            : Icons.visibility),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final class DirectConnectionAdvancedSettingsSection extends StatelessWidget {
  const DirectConnectionAdvancedSettingsSection({
    super.key,
    required this.form,
    this.flat = false,
  });

  final DirectConnectionEditorForm form;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final usesCupertinoChrome = context.usesCupertinoChrome;
    return UtilityDisclosureSection(
      key: const ValueKey<String>('direct-advanced-settings-toggle'),
      title: l10n.advancedSettings,
      flat: flat,
      subtitle: form.customHeaders.isEmpty
          ? null
          : '${l10n.directCustomHeaders}: ${form.customHeaders.length}',
      leading: Icon(
        usesCupertinoChrome ? CupertinoIcons.gear_alt : Icons.tune_rounded,
        color: theme.iconSecondary,
        size: IconSize.medium,
      ),
      expanded: form.showAdvancedSettings,
      onChanged: form.setShowAdvancedSettings,
      child: _AdvancedSettingsContent(form: form),
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
    final usesCupertinoChrome = context.usesCupertinoChrome;

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
                    style: theme.bodySmall?.copyWith(
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
        AccessibleFormField(
          key: const ValueKey<String>('direct-custom-header-name-field'),
          label: l10n.headerName,
          hint: 'X-Custom-Header',
          controller: form.headerName,
          errorText: directHeaderValidationMessage(l10n, form.headerError),
          textInputAction: TextInputAction.next,
          autocorrect: false,
          onSubmitted: (_) => form.headerValueFocusNode.requestFocus(),
        ),
        const SizedBox(height: Spacing.md),
        AccessibleFormField(
          key: const ValueKey<String>('direct-custom-header-value-field'),
          label: l10n.headerValue,
          hint: l10n.headerValueHint,
          controller: form.headerValue,
          focusNode: form.headerValueFocusNode,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          onSubmitted: (_) {
            if (form.canAddCustomHeader) form.addCustomHeader();
          },
        ),
        const SizedBox(height: Spacing.md),
        ConduitButton(
          key: const ValueKey<String>('add-direct-custom-header-button'),
          text: l10n.addHeader,
          isSecondary: true,
          isFullWidth: true,
          useNativeLabel: true,
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
                      icon: usesCupertinoChrome
                          ? CupertinoIcons.xmark
                          : Icons.close_rounded,
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
        AccessibleFormField(
          key: const ValueKey<String>('direct-model-prefix-field'),
          label: l10n.directModelIdPrefix,
          hint: 'studio',
          controller: form.modelIdPrefix,
          textInputAction: TextInputAction.next,
          autocorrect: false,
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          l10n.directModelIdPrefixDescription,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.md),
        AccessibleFormField(
          key: const ValueKey<String>('direct-model-tags-field'),
          label: l10n.directModelTags,
          hint: 'local, private',
          controller: form.tags,
          textInputAction: TextInputAction.next,
          autocorrect: false,
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          l10n.directModelTagsDescription,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.xl),
        AccessibleFormField(
          key: const ValueKey<String>('direct-manual-models-field'),
          label: l10n.directManualModelIds,
          hint: 'model-a\nmodel-b',
          controller: form.models,
          minLines: 3,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          autocorrect: false,
        ),
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
          style: AppTypography.bodySmallStyle.copyWith(
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
          AccessibleFormField(
            key: const ValueKey<String>('direct-api-version-field'),
            label: l10n.directApiVersion,
            hint: '2024-10-21',
            controller: form.apiVersion,
            textInputAction: TextInputAction.next,
            autocorrect: false,
          ),
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
