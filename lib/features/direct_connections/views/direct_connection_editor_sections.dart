part of 'direct_connection_editor_page.dart';

extension _DirectConnectionEditorSections on _DirectConnectionEditorPageState {
  Widget _buildAvailabilitySection() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      title: l10n.enabledLabel,
      child: InkWell(
        onTap: () => _mutate(() => _enabled = !_enabled),
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
            AdaptiveSwitch(
              value: _enabled,
              onChanged: (value) => _mutate(() => _enabled = value),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProviderSection() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    if (widget.isOpenWebUi) {
      return InsetGroupedSection(
        title: l10n.directProvider,
        child: Row(
          children: [
            _providerIcon(
              context.usesCupertinoChrome
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

    return InsetGroupedSection(
      key: const ValueKey<String>('direct-provider-preset-selector'),
      title: l10n.directProvider,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Column(
        children: [
          UtilitySelectionRow(
            leading: _providerIcon(
              context.usesCupertinoChrome
                  ? CupertinoIcons.chevron_left_slash_chevron_right
                  : Icons.api_rounded,
            ),
            title: l10n.openAICompatible,
            subtitle: l10n.directChatCompletionsDescription,
            selected: _providerPreset == kOpenAiCompatibleAdapterKey,
            showDivider: true,
            onTap: () => _selectProviderPreset(kOpenAiCompatibleAdapterKey),
          ),
          UtilitySelectionRow(
            leading: _providerIcon(
              context.usesCupertinoChrome
                  ? CupertinoIcons.compass
                  : Icons.explore_outlined,
            ),
            title: l10n.openRouterProviderName,
            subtitle: l10n.directOpenRouterBaseUrlDescription,
            selected: _providerPreset == kOpenRouterProviderPreset,
            showDivider: true,
            onTap: () => _selectProviderPreset(kOpenRouterProviderPreset),
          ),
          UtilitySelectionRow(
            leading: _providerIcon(
              context.usesCupertinoChrome
                  ? CupertinoIcons.desktopcomputer
                  : Icons.computer_outlined,
            ),
            title: l10n.ollama,
            subtitle: l10n.ollamaCloudBaseUrlDescription,
            selected: _providerPreset == kOllamaAdapterKey,
            onTap: () => _selectProviderPreset(kOllamaAdapterKey),
          ),
        ],
      ),
    );
  }

  Widget _providerIcon(IconData icon) {
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

  void _selectProviderPreset(String value) {
    if (_providerPreset == value) return;
    final l10n = AppLocalizations.of(context)!;
    _mutate(() {
      _providerPreset = value;
      _adapterKey = value == kOllamaAdapterKey
          ? kOllamaAdapterKey
          : kOpenAiCompatibleAdapterKey;
      if (value == kOpenRouterProviderPreset) {
        _authentication = DirectAuthenticationMode.bearer;
        _openAiApiMode = DirectOpenAiApiMode.chatCompletions;
      }
      _attempt = const ConnectionAttemptState.idle();
      _draftController.baseUrl.text = switch (value) {
        kOllamaAdapterKey => 'https://ollama.com',
        kOpenRouterProviderPreset => kOpenRouterApiBaseUrl,
        _ => 'https://api.openai.com/v1',
      };
      if (value != kOpenRouterProviderPreset) {
        _authentication = DirectAuthenticationMode.bearer;
        _openAiApiMode = DirectOpenAiApiMode.chatCompletions;
      }
      if (widget.isNew &&
          (_draftController.name.text == 'My provider' ||
              _draftController.name.text == l10n.ollamaCloudDefaultName ||
              _draftController.name.text == l10n.openRouterProviderName)) {
        _draftController.name.text = switch (value) {
          kOllamaAdapterKey => l10n.ollamaCloudDefaultName,
          kOpenRouterProviderPreset => l10n.openRouterProviderName,
          _ => 'My provider',
        };
      }
    });
  }

  Widget _buildConnectionDetailsSection({
    required bool isOllama,
    required bool isOpenRouter,
  }) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final usesCupertinoChrome = context.usesCupertinoChrome;
    return InsetGroupedSection(
      title: l10n.directConnectionDetailsTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.isOpenWebUi) ...[
            AccessibleFormField(
              key: const ValueKey<String>('direct-connection-name-field'),
              label: l10n.directConnectionName,
              hint: isOllama
                  ? l10n.ollamaCloudDefaultName
                  : isOpenRouter
                  ? l10n.openRouterProviderName
                  : 'My provider',
              controller: _draftController.name,
              errorText: _nameError,
              isRequired: true,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _clearTransientState(),
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
            controller: _draftController.baseUrl,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            errorText: _urlError,
            isRequired: true,
            onChanged: (_) => _invalidateOriginSecretConfirmation(),
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
                'direct-authentication-selector-$_providerPreset',
              ),
              initialValue: _authentication,
              isExpanded: true,
              decoration: context.conduitInputStyles.standard(),
              dropdownColor: theme.surfaceBackground,
              items: [
                DropdownMenuItem(
                  value: DirectAuthenticationMode.bearer,
                  child: Text(l10n.bearerToken),
                ),
                if (!widget.isOpenWebUi && !isOpenRouter)
                  DropdownMenuItem(
                    value: DirectAuthenticationMode.apiKeyHeader,
                    child: Text(l10n.directApiKeyHeader),
                  ),
                if (widget.isOpenWebUi || !isOpenRouter)
                  DropdownMenuItem(
                    value: DirectAuthenticationMode.none,
                    child: Text(l10n.noAuthentication),
                  ),
                if (_authentication == DirectAuthenticationMode.unsupported)
                  DropdownMenuItem(
                    value: DirectAuthenticationMode.unsupported,
                    enabled: false,
                    child: Text(l10n.directConnectionUnavailableLabel),
                  ),
              ],
              onChanged: (value) {
                if (value == null ||
                    value == DirectAuthenticationMode.unsupported) {
                  return;
                }
                _mutate(() {
                  _authentication = value;
                  _apiKeyDirty = true;
                  _originSecretsConfirmed = false;
                  _apiKeyError = null;
                  _attempt = const ConnectionAttemptState.idle();
                });
              },
            ),
          ),
          if (_authentication == DirectAuthenticationMode.apiKeyHeader) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              l10n.directApiKeyHeaderDescription,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ],
          if (_authentication == DirectAuthenticationMode.unsupported) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              l10n.openWebUiDirectConnectionUnsupportedAuth,
              style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
            ),
          ],
          if (_authentication == DirectAuthenticationMode.bearer ||
              _authentication == DirectAuthenticationMode.apiKeyHeader) ...[
            const SizedBox(height: Spacing.md),
            AccessibleFormField(
              key: const ValueKey<String>('direct-api-key-field'),
              label: l10n.directApiKey,
              hint: (_savedProfile?.apiKey ?? '').isNotEmpty
                  ? l10n.directConfiguredReplacePlaceholder
                  : l10n.directApiKeyPlaceholder,
              controller: _draftController.apiKey,
              obscureText: !_showApiKey,
              errorText: _apiKeyError,
              isRequired: requiresDirectApiKey(
                authentication: _authentication,
                isOpenWebUi: widget.isOpenWebUi,
                isNew: widget.isNew,
                savedOpenWebUiAuthType: _savedOpenWebUiRecord?.authType,
                apiKeyDirty: _apiKeyDirty,
                originChanged: _originChanged,
              ),
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              suffixIcon: IconButton(
                tooltip: _showApiKey ? l10n.hidePassword : l10n.showPassword,
                onPressed: () => _mutate(() => _showApiKey = !_showApiKey),
                icon: Icon(
                  _showApiKey
                      ? (usesCupertinoChrome
                            ? CupertinoIcons.eye_slash
                            : Icons.visibility_off)
                      : (usesCupertinoChrome
                            ? CupertinoIcons.eye
                            : Icons.visibility),
                ),
              ),
              onChanged: (_) {
                _apiKeyDirty = true;
                _invalidateOriginSecretConfirmation();
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAdvancedSettings() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final usesCupertinoChrome = context.usesCupertinoChrome;
    return UtilityDisclosureSection(
      key: const ValueKey<String>('direct-advanced-settings-toggle'),
      title: l10n.advancedSettings,
      subtitle: _draftController.customHeaders.isEmpty
          ? null
          : '${l10n.directCustomHeaders}: ${_draftController.customHeaders.length}',
      leading: Icon(
        usesCupertinoChrome ? CupertinoIcons.gear_alt : Icons.tune_rounded,
        color: theme.iconSecondary,
        size: IconSize.medium,
      ),
      expanded: _showAdvancedSettings,
      onChanged: (value) => _mutate(() => _showAdvancedSettings = value),
      child: _buildAdvancedSettingsContent(),
    );
  }

  Widget _buildAdvancedSettingsContent() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final usesCupertinoChrome = context.usesCupertinoChrome;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_adapterKey != kOllamaAdapterKey) ...[
          _buildAdvancedApiBehavior(),
          const SizedBox(height: Spacing.xl),
          Divider(height: BorderWidth.thin, color: theme.dividerColor),
          const SizedBox(height: Spacing.lg),
        ],
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                if (_draftController.customHeaders.isNotEmpty)
                  Text(
                    '${_draftController.customHeaders.length}',
                    style: theme.bodySmall?.copyWith(color: theme.textTertiary),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            AccessibleFormField(
              key: const ValueKey<String>('direct-custom-header-name-field'),
              label: l10n.headerName,
              hint: 'X-Custom-Header',
              controller: _draftController.headerName,
              errorText: _headersError,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              onChanged: (_) => _mutate(() {
                _headersError = null;
                _formError = null;
              }),
              onSubmitted: (_) =>
                  _draftController.headerValueFocusNode.requestFocus(),
            ),
            const SizedBox(height: Spacing.md),
            AccessibleFormField(
              key: const ValueKey<String>('direct-custom-header-value-field'),
              label: l10n.headerValue,
              hint: l10n.headerValueHint,
              controller: _draftController.headerValue,
              focusNode: _draftController.headerValueFocusNode,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              onChanged: (_) => _mutate(() {
                _headersError = null;
                _formError = null;
              }),
              onSubmitted: (_) {
                if (_canAddCustomHeader) {
                  _addCustomHeader();
                }
              },
            ),
            const SizedBox(height: Spacing.md),
            ConduitButton(
              key: const ValueKey<String>('add-direct-custom-header-button'),
              text: l10n.addHeader,
              isSecondary: true,
              isFullWidth: true,
              useNativeLabel: true,
              onPressed: _canAddCustomHeader ? () => _addCustomHeader() : null,
            ),
            if (_draftController.customHeaders.isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              for (final entry in _draftController.customHeaders.entries)
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
                      borderRadius: BorderRadius.circular(
                        AppBorderRadius.small,
                      ),
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
                          onPressed: () => _removeCustomHeader(entry.key),
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
              controller: _draftController.modelIdPrefix,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              onChanged: (_) => _clearTransientState(),
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
              controller: _draftController.tags,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              onChanged: (_) => _clearTransientState(),
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
              controller: _draftController.models,
              minLines: 3,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              autocorrect: false,
              onChanged: (_) => _clearTransientState(),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              l10n.directManualModelIdsDescription,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAdvancedApiBehavior() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final isOpenRouter = _providerPreset == kOpenRouterProviderPreset;
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
        if (isOpenRouter)
          Text(
            l10n.directOpenRouterChatCompletionsDescription,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          )
        else ...[
          AdaptiveSegmentedSelector<DirectOpenAiApiMode>(
            key: const ValueKey<String>('direct-openai-api-mode-selector'),
            value: _openAiApiMode,
            showIcons: false,
            onChanged: (value) => _mutate(() {
              _openAiApiMode = value;
              _attempt = const ConnectionAttemptState.idle();
            }),
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
            _openAiApiMode == DirectOpenAiApiMode.responses
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
            controller: _draftController.apiVersion,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            onChanged: (_) => _clearTransientState(),
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
