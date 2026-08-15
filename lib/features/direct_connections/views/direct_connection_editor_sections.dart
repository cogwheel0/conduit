import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../../shared/widgets/adaptive_dropdown_field.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../profile/widgets/adaptive_segmented_selector.dart';
import '../controllers/direct_connection_editor_draft.dart';
import '../controllers/direct_connection_editor_form.dart';
import '../controllers/direct_custom_headers_controller.dart';
import '../models/direct_connection_profile.dart';

part 'direct_connection_advanced_settings.dart';

final class DirectConnectionAvailabilitySection extends StatelessWidget {
  const DirectConnectionAvailabilitySection({super.key, required this.form});

  final DirectConnectionEditorForm form;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      child: InkWell(
        onTap: () {
          ConduitHaptics.selectionClick();
          form.setEnabled(!form.enabled);
        },
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

/// The compact first group used by the iOS editor.
///
/// Availability and provider are both connection identity, so presenting them
/// as one list creates a single entry point before the editable credentials.
final class DirectConnectionGeneralSection extends StatelessWidget {
  const DirectConnectionGeneralSection({super.key, required this.form});

  final DirectConnectionEditorForm form;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedList(
      useNativeSurface: true,
      footer: form.policy.editsProvider
          ? l10n.directConnectionEnabledSubtitle
          : l10n.openWebUiDirectConnectionProviderDescription,
      children: [
        UtilityRow(
          title: l10n.enabledLabel,
          titleFontWeight: FontWeight.w400,
          preserveTrailingSemantics: true,
          trailing: AdaptiveSwitch(
            value: form.enabled,
            onChanged: form.setEnabled,
          ),
          onTap: () => form.setEnabled(!form.enabled),
        ),
        _NativeProviderRow(form: form),
      ],
    );
  }
}

List<AdaptiveDropdownOption<String>> _providerOptions(AppLocalizations l10n) =>
    [
      AdaptiveDropdownOption(
        value: kOpenAiCompatibleAdapterKey,
        label: l10n.openAICompatible,
      ),
      AdaptiveDropdownOption(
        value: kOpenRouterProviderPreset,
        label: l10n.openRouterProviderName,
      ),
      AdaptiveDropdownOption(value: kOllamaAdapterKey, label: l10n.ollama),
    ];

List<AdaptiveDropdownOption<String>> _providerOptionsForForm(
  AppLocalizations l10n,
  DirectConnectionEditorForm form,
) {
  final options = _providerOptions(l10n);
  if (options.any((option) => option.value == form.providerPreset)) {
    return options;
  }
  return [
    AdaptiveDropdownOption(
      value: form.providerPreset,
      label: form.providerPreset,
      enabled: false,
    ),
    ...options,
  ];
}

void _selectProvider(
  DirectConnectionEditorForm form,
  AppLocalizations l10n,
  String value,
) => form.selectProviderPreset(
  value,
  ollamaDefaultName: l10n.ollamaCloudDefaultName,
  openRouterDefaultName: l10n.openRouterProviderName,
);

final class _NativeProviderRow extends StatelessWidget {
  const _NativeProviderRow({required this.form});

  final DirectConnectionEditorForm form;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final options = _providerOptionsForForm(l10n, form);
    final currentLabel = form.policy.editsProvider
        ? options
              .firstWhere((option) => option.value == form.providerPreset)
              .label
        : l10n.openAICompatible;
    final row = UtilityValueRow(
      label: l10n.directProvider,
      value: currentLabel,
      titleFontWeight: FontWeight.w400,
      valueFontWeight: FontWeight.w400,
      valueTextStyle: AppTypography.bodyMediumStyle,
      selectable: false,
      showChevron: form.policy.editsProvider,
    );
    if (!form.policy.editsProvider) return row;
    return AdaptiveSingleChoiceTrigger<String>(
      key: const ValueKey<String>('direct-provider-preset-selector'),
      value: form.providerPreset,
      options: options,
      onChanged: (value) => _selectProvider(form, l10n, value),
      nativeTitle: l10n.directProvider,
      semanticLabel: '$currentLabel, ${l10n.directProvider}',
      child: row,
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
      if (PlatformInfo.isIOS) {
        return InsetGroupedList(
          useNativeSurface: true,
          footer: l10n.openWebUiDirectConnectionProviderDescription,
          children: [_NativeProviderRow(form: form)],
        );
      }
      return InsetGroupedSection(
        title: l10n.directProvider,
        flat: flat,
        child: Row(
          children: [
            _ProviderIcon(icon: Icons.cloud_outlined),
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

    void select(String value) => _selectProvider(form, l10n, value);

    if (PlatformInfo.isIOS) {
      return InsetGroupedList(
        useNativeSurface: true,
        children: [_NativeProviderRow(form: form)],
      );
    }

    return InsetGroupedSection(
      key: const ValueKey<String>('direct-provider-preset-selector'),
      title: l10n.directProvider,
      flat: flat,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Column(
        children: [
          UtilitySelectionRow(
            leading: const _ProviderIcon(icon: Icons.api_rounded),
            title: l10n.openAICompatible,
            subtitle: null,
            selected: form.providerPreset == kOpenAiCompatibleAdapterKey,
            showDivider: true,
            onTap: () => select(kOpenAiCompatibleAdapterKey),
          ),
          UtilitySelectionRow(
            leading: const _ProviderIcon(icon: Icons.explore_outlined),
            title: l10n.openRouterProviderName,
            subtitle: null,
            selected: form.providerPreset == kOpenRouterProviderPreset,
            showDivider: true,
            onTap: () => select(kOpenRouterProviderPreset),
          ),
          UtilitySelectionRow(
            leading: const _ProviderIcon(icon: Icons.computer_outlined),
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
    final native = PlatformInfo.isIOS;
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final isOllama = form.isOllama;
    final isOpenRouter = form.isOpenRouter;
    final baseUrlDescription = isOllama
        ? l10n.ollamaCloudBaseUrlDescription
        : isOpenRouter
        ? l10n.directOpenRouterBaseUrlDescription
        : l10n.directBaseUrlDescription;
    final authenticationOptions = _authenticationOptions(l10n, form);

    final nameField = AccessibleFormField(
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
      iosSettingsRow: native,
      textInputAction: TextInputAction.next,
    );
    final baseUrlField = AccessibleFormField(
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
      iosSettingsRow: native,
      iosLabelFlex: 4,
    );
    final authenticationField = native
        ? _NativeAuthenticationSelector(
            key: ValueKey<String>(
              'direct-authentication-selector-${form.providerPreset}',
            ),
            value: form.authentication,
            options: authenticationOptions,
            onChanged: form.setAuthentication,
          )
        : Material(
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
                for (final option in authenticationOptions)
                  DropdownMenuItem(
                    value: option.value,
                    enabled: option.enabled,
                    child: Text(option.label),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                ConduitHaptics.selectionClick();
                form.setAuthentication(value);
              },
            ),
          );
    final showsApiKey =
        form.authentication == DirectAuthenticationMode.bearer ||
        form.authentication == DirectAuthenticationMode.apiKeyHeader;
    final apiKeyField = AccessibleFormField(
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
      iosSettingsRow: native,
      iosLabelFlex: 4,
      suffixIcon: ConduitIconButton(
        tooltip: form.showApiKey ? l10n.hidePassword : l10n.showPassword,
        onPressed: () => form.setShowApiKey(!form.showApiKey),
        icon: form.showApiKey
            ? (context.usesCupertinoChrome
                  ? CupertinoIcons.eye_slash
                  : Icons.visibility_off)
            : (context.usesCupertinoChrome
                  ? CupertinoIcons.eye
                  : Icons.visibility),
        backgroundColor: native ? Colors.transparent : null,
        iconColor: native ? theme.iconSecondary : null,
        isCompact: native,
      ),
    );

    if (native) {
      return InsetGroupedList(
        footer: [
          baseUrlDescription,
          if (form.authentication == DirectAuthenticationMode.apiKeyHeader)
            l10n.directApiKeyHeaderDescription,
          if (form.authentication == DirectAuthenticationMode.unsupported)
            l10n.openWebUiDirectConnectionUnsupportedAuth,
        ].join('\n\n'),
        useNativeSurface: true,
        children: [
          if (form.policy.editsName) nameField,
          baseUrlField,
          authenticationField,
          if (showsApiKey) apiKeyField,
        ],
      );
    }

    return InsetGroupedSection(
      title: l10n.directConnectionDetailsTitle,
      flat: flat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (form.policy.editsName) ...[
            nameField,
            const SizedBox(height: Spacing.md),
          ],
          baseUrlField,
          const SizedBox(height: Spacing.sm),
          Text(
            baseUrlDescription,
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
          authenticationField,
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
          if (showsApiKey) ...[const SizedBox(height: Spacing.md), apiKeyField],
        ],
      ),
    );
  }
}

List<({DirectAuthenticationMode value, String label, bool enabled})>
_authenticationOptions(
  AppLocalizations l10n,
  DirectConnectionEditorForm form,
) => [
  (
    value: DirectAuthenticationMode.bearer,
    label: l10n.bearerToken,
    enabled: true,
  ),
  if (form.canSelectApiKeyHeader)
    (
      value: DirectAuthenticationMode.apiKeyHeader,
      label: l10n.directApiKeyHeader,
      enabled: true,
    ),
  if (form.canSelectNoAuthentication)
    (
      value: DirectAuthenticationMode.none,
      label: l10n.noAuthentication,
      enabled: true,
    ),
  if (form.authentication == DirectAuthenticationMode.unsupported)
    (
      value: DirectAuthenticationMode.unsupported,
      label: l10n.directConnectionUnavailableLabel,
      enabled: false,
    ),
];

class _NativeAuthenticationSelector extends StatelessWidget {
  const _NativeAuthenticationSelector({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final DirectAuthenticationMode value;
  final List<({DirectAuthenticationMode value, String label, bool enabled})>
  options;
  final ValueChanged<DirectAuthenticationMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = options
        .firstWhere(
          (option) => option.value == value,
          orElse: () => options.first,
        )
        .label;
    return AdaptiveSingleChoiceTrigger<DirectAuthenticationMode>(
      value: value,
      options: [
        for (final option in options)
          AdaptiveDropdownOption(
            value: option.value,
            label: option.label,
            enabled: option.enabled,
          ),
      ],
      onChanged: onChanged,
      nativeTitle: l10n.directAuthentication,
      semanticLabel: '${l10n.directAuthentication}, $label',
      child: UtilityValueRow(
        label: l10n.directAuthentication,
        value: label,
        titleFontWeight: FontWeight.w400,
        valueFontWeight: FontWeight.w400,
        valueTextStyle: AppTypography.bodyMediumStyle,
        selectable: false,
        showChevron: true,
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
    if (PlatformInfo.isIOS) {
      final headerError = directHeaderValidationMessage(l10n, form.headerError);
      return InsetGroupedList(
        useNativeSurface: true,
        children: [
          UtilityRow(
            key: const ValueKey<String>('direct-advanced-settings-toggle'),
            title: l10n.advancedSettings,
            subtitle:
                headerError ??
                (form.customHeaders.isEmpty
                    ? null
                    : '${l10n.directCustomHeaders}: ${form.customHeaders.length}'),
            titleFontWeight: FontWeight.w400,
            foregroundColor: headerError == null
                ? null
                : CupertinoColors.systemRed.resolveFrom(context),
            showChevron: true,
            onTap: () => showDirectConnectionAdvancedSettings(context, form),
          ),
        ],
      );
    }
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
