import 'dart:convert';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../auth/widgets/adaptive_auth_scaffold.dart';
import '../../profile/widgets/adaptive_segmented_selector.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../providers/direct_connection_providers.dart';

enum DirectAuthenticationMode { bearer, apiKeyHeader, none }

@visibleForTesting
Map<String, String> parseDirectCustomHeaders(String source) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) return const {};
  final decoded = jsonDecode(trimmed);
  if (decoded is! Map) {
    throw const FormatException('Enter a JSON object.');
  }
  final result = <String, String>{};
  for (final entry in decoded.entries) {
    if (entry.key is! String || entry.value is! String) {
      throw const FormatException('Header names and values must be text.');
    }
    result[(entry.key as String).trim()] = entry.value as String;
  }
  return result;
}

@visibleForTesting
List<String> parseDirectManualModelIds(String source) {
  final seen = <String>{};
  return [
    for (final line in source.split(RegExp(r'[\r\n,]+')))
      if (line.trim().isNotEmpty && seen.add(line.trim())) line.trim(),
  ];
}

@visibleForTesting
List<String> parseDirectModelTags(String source) =>
    parseDirectManualModelIds(source);

@visibleForTesting
String normalizeDirectBaseUrl(String source) {
  var value = source.trim();
  while (value.endsWith('/') && Uri.tryParse(value)?.path != '/') {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

@visibleForTesting
DirectConnectionProfile secureDirectDraftForEditedOrigin({
  required DirectConnectionProfile? previous,
  required DirectConnectionProfile draft,
  required bool secretsConfirmedForNewOrigin,
}) {
  if (previous == null) return draft;
  return DirectConnectionProfile.secureUpdate(
    previous: previous,
    next: draft,
    secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
  );
}

@visibleForTesting
bool requiresDirectOriginCredentialConfirmation({
  required DirectConnectionProfile? previous,
  required DirectConnectionProfile draft,
}) {
  if (previous == null || previous.origin == draft.origin) return false;
  final previousHasCredentials =
      (previous.apiKey?.isNotEmpty ?? false) ||
      previous.customHeaders.isNotEmpty;
  final draftHasCredentials =
      (draft.apiKey?.isNotEmpty ?? false) || draft.customHeaders.isNotEmpty;
  return previousHasCredentials && draftHasCredentials;
}

class DirectConnectionEditorPage extends ConsumerStatefulWidget {
  const DirectConnectionEditorPage({
    super.key,
    required this.profileId,
    this.isOnboarding = false,
  });

  final String profileId;
  final bool isOnboarding;

  bool get isNew => profileId == 'new';

  @override
  ConsumerState<DirectConnectionEditorPage> createState() =>
      _DirectConnectionEditorPageState();
}

class _DirectConnectionEditorPageState
    extends ConsumerState<DirectConnectionEditorPage> {
  final _nameController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _apiVersionController = TextEditingController();
  final _modelIdPrefixController = TextEditingController();
  final _tagsController = TextEditingController();
  final _headerNameController = TextEditingController();
  final _headerValueController = TextEditingController();
  final _modelsController = TextEditingController();
  final _headerValueFocusNode = FocusNode();
  final Map<String, String> _customHeaders = {};

  DirectConnectionProfile? _savedProfile;
  String _adapterKey = kOpenAiCompatibleAdapterKey;
  DirectOpenAiApiMode _openAiApiMode = DirectOpenAiApiMode.chatCompletions;
  DirectAuthenticationMode _authentication = DirectAuthenticationMode.bearer;
  bool _enabled = true;
  bool _hydrated = false;
  bool _apiKeyDirty = false;
  bool _headersDirty = false;
  bool _showApiKey = false;
  bool _showAdvancedSettings = false;
  bool _saving = false;
  bool _testing = false;
  bool _deleting = false;
  bool _originSecretsConfirmed = false;
  bool? _testSucceeded;
  String? _testMessage;
  String? _nameError;
  String? _urlError;
  String? _apiKeyError;
  String? _headersError;
  String? _formError;

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _apiVersionController.dispose();
    _modelIdPrefixController.dispose();
    _tagsController.dispose();
    _headerNameController.dispose();
    _headerValueController.dispose();
    _modelsController.dispose();
    _headerValueFocusNode.dispose();
    super.dispose();
  }

  void _hydrate(DirectConnectionProfile? profile) {
    if (_hydrated) return;
    _hydrated = true;
    _savedProfile = profile;
    if (profile == null) {
      _nameController.text = 'My provider';
      _baseUrlController.text = 'https://api.openai.com/v1';
      return;
    }
    _nameController.text = profile.name;
    _baseUrlController.text = profile.baseUrl;
    _customHeaders
      ..clear()
      ..addAll(profile.customHeaders);
    _modelsController.text = profile.manualModelIds.join('\n');
    _apiVersionController.text = profile.apiVersion ?? '';
    _modelIdPrefixController.text = profile.modelIdPrefix ?? '';
    _tagsController.text = profile.tags.join(', ');
    _adapterKey = profile.adapterKey;
    _openAiApiMode = profile.openAiApiMode;
    _authentication = (profile.apiKey ?? '').isEmpty
        ? DirectAuthenticationMode.none
        : switch (profile.apiKeyAuthMode) {
            DirectApiKeyAuthMode.bearer => DirectAuthenticationMode.bearer,
            DirectApiKeyAuthMode.apiKeyHeader =>
              DirectAuthenticationMode.apiKeyHeader,
          };
    _enabled = profile.enabled;
  }

  DirectConnectionProfile? _profileById(
    List<DirectConnectionProfile> profiles,
  ) {
    if (widget.isNew) return null;
    for (final profile in profiles) {
      if (profile.id == widget.profileId) return profile;
    }
    return null;
  }

  bool get _originChanged {
    final saved = _savedProfile;
    if (saved == null) return false;
    return DirectConnectionProfile.originOf(saved.baseUrl) !=
        DirectConnectionProfile.originOf(_baseUrlController.text);
  }

  bool get _savedHasOriginBoundSecrets {
    final saved = _savedProfile;
    return saved != null &&
        ((saved.apiKey?.isNotEmpty ?? false) || saved.customHeaders.isNotEmpty);
  }

  bool get _busy => _saving || _testing || _deleting;

  // Empty header values are valid HTTP and are supported by the persisted
  // profile model. A name is therefore enough to add a pending header.
  bool get _canAddCustomHeader => _headerNameController.text.trim().isNotEmpty;

  bool get _originBoundSecretsReviewed {
    final saved = _savedProfile;
    if (saved == null || !_originChanged) return true;
    final apiKeyReviewed = !(saved.apiKey?.isNotEmpty ?? false) || _apiKeyDirty;
    final headersReviewed = saved.customHeaders.isEmpty || _headersDirty;
    return apiKeyReviewed && headersReviewed;
  }

  DirectConnectionProfile? _buildDraft({required bool validateFields}) {
    final l10n = AppLocalizations.of(context)!;
    final name = _nameController.text.trim();
    final baseUrl = normalizeDirectBaseUrl(_baseUrlController.text);
    var valid = true;

    String? nameError;
    String? urlError;
    String? apiKeyError;
    final pendingHeaderReady = !validateFields || _commitPendingCustomHeader();
    if (!pendingHeaderReady) valid = false;

    if (name.isEmpty) {
      valid = false;
      nameError = l10n.directConnectionNameRequired;
    }
    if (DirectConnectionProfile.originOf(baseUrl) == null) {
      valid = false;
      urlError = l10n.directConnectionUrlInvalid;
    } else if (!_originBoundSecretsReviewed) {
      valid = false;
      urlError = l10n.directConnectionCredentialsReentryRequired;
    }

    final existingApiKey = _savedProfile?.apiKey?.trim() ?? '';
    final enteredApiKey = _apiKeyController.text.trim();
    final apiKey = switch (_authentication) {
      DirectAuthenticationMode.none => null,
      DirectAuthenticationMode.bearer ||
      DirectAuthenticationMode.apiKeyHeader =>
        _apiKeyDirty || _originChanged ? enteredApiKey : existingApiKey,
    };
    if (_authentication != DirectAuthenticationMode.none &&
        (apiKey ?? '').isEmpty) {
      valid = false;
      apiKeyError = l10n.directConnectionApiKeyRequired;
    }

    final headers = Map<String, String>.from(_customHeaders);

    if (validateFields) {
      setState(() {
        _nameError = nameError;
        _urlError = urlError;
        _apiKeyError = apiKeyError;
        _formError = null;
      });
    }
    if (!valid) return null;

    final saved = _savedProfile;
    final profile = DirectConnectionProfile(
      id: saved?.id ?? const Uuid().v4(),
      name: name,
      adapterKey: _adapterKey,
      baseUrl: baseUrl,
      openAiApiMode: _openAiApiMode,
      apiKeyAuthMode: _authentication == DirectAuthenticationMode.apiKeyHeader
          ? DirectApiKeyAuthMode.apiKeyHeader
          : DirectApiKeyAuthMode.bearer,
      apiVersion: _apiVersionController.text.trim().isEmpty
          ? null
          : _apiVersionController.text.trim(),
      modelIdPrefix: _modelIdPrefixController.text.trim().isEmpty
          ? null
          : _modelIdPrefixController.text.trim(),
      tags: parseDirectModelTags(_tagsController.text),
      enabled: _enabled,
      apiKey: apiKey,
      customHeaders: headers,
      manualModelIds: parseDirectManualModelIds(_modelsController.text),
      allowSelfSignedCertificates: saved?.allowSelfSignedCertificates ?? false,
      mtlsCertificateChainPem: saved?.mtlsCertificateChainPem,
      mtlsCertificateLabel: saved?.mtlsCertificateLabel,
      mtlsPrivateKeyPem: saved?.mtlsPrivateKeyPem,
      mtlsPrivateKeyLabel: saved?.mtlsPrivateKeyLabel,
      mtlsPrivateKeyPassword: saved?.mtlsPrivateKeyPassword,
    );
    // Apply the origin-binding boundary before this draft can be probed. Save
    // also enforces it in the repository, but Test connection intentionally
    // operates on an unpersisted draft and must never inherit TLS material for
    // a different host.
    final safeProfile = secureDirectDraftForEditedOrigin(
      previous: saved,
      draft: profile,
      secretsConfirmedForNewOrigin: _originBoundSecretsReviewed,
    );
    final profileError = safeProfile.validateOrNull();
    if (profileError != null) {
      if (validateFields) setState(() => _formError = profileError);
      return null;
    }
    return safeProfile;
  }

  void _clearTransientState() {
    setState(() {
      _nameError = null;
      _urlError = null;
      _apiKeyError = null;
      _headersError = null;
      _formError = null;
      _testSucceeded = null;
      _testMessage = null;
    });
  }

  void _invalidateOriginSecretConfirmation() {
    _originSecretsConfirmed = false;
    _clearTransientState();
  }

  String? _validateHeaderName(String source) {
    final name = source.trim();
    final l10n = AppLocalizations.of(context)!;
    if (name.isEmpty) return null;
    if (!DirectConnectionProfile.isValidCustomHeaderName(name)) {
      return l10n.headerNameInvalidChars;
    }
    if (DirectConnectionProfile.reservedHeaderNames.contains(
      name.toLowerCase(),
    )) {
      return l10n.headerNameReserved(name);
    }
    final duplicate = _customHeaders.keys.any(
      (existing) => existing.toLowerCase() == name.toLowerCase(),
    );
    if (duplicate) return l10n.headerAlreadyExists(name);
    return null;
  }

  String? _validateHeaderValue(String source) {
    if (!DirectConnectionProfile.isValidCustomHeaderValue(source)) {
      return AppLocalizations.of(context)!.headerValueInvalidChars;
    }
    return null;
  }

  bool _commitPendingCustomHeader() {
    final hasName = _headerNameController.text.trim().isNotEmpty;
    final hasValue = _headerValueController.text.isNotEmpty;
    if (!hasName && !hasValue) return true;
    if (!hasName) {
      setState(() {
        _showAdvancedSettings = true;
        _headersError = AppLocalizations.of(
          context,
        )!.directConnectionHeaderNameRequired;
      });
      return false;
    }
    return _addCustomHeader();
  }

  void _markHeadersChanged() {
    _headersDirty = true;
    _originSecretsConfirmed = false;
    _headersError = null;
    _formError = null;
    _testSucceeded = null;
    _testMessage = null;
  }

  bool _addCustomHeader() {
    if (!_canAddCustomHeader) return false;
    final name = _headerNameController.text.trim();
    final value = _headerValueController.text;
    final error = _validateHeaderName(name) ?? _validateHeaderValue(value);
    if (error != null) {
      setState(() {
        _showAdvancedSettings = true;
        _headersError = error;
      });
      return false;
    }

    setState(() {
      _customHeaders[name] = value;
      _headerNameController.clear();
      _headerValueController.clear();
      _markHeadersChanged();
    });
    return true;
  }

  void _removeCustomHeader(String name) {
    setState(() {
      _customHeaders.remove(name);
      _markHeadersChanged();
    });
  }

  Future<bool> _confirmOriginSecretTransfer(
    DirectConnectionProfile draft,
  ) async {
    if (_originSecretsConfirmed ||
        !requiresDirectOriginCredentialConfirmation(
          previous: _savedProfile,
          draft: draft,
        )) {
      return true;
    }
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.directConnectionCredentialTransferTitle,
      message: l10n.directConnectionCredentialTransferMessage,
      confirmText: l10n.directConnectionCredentialTransferConfirm,
      barrierDismissible: false,
    );
    if (confirmed && mounted) {
      setState(() => _originSecretsConfirmed = true);
    }
    return confirmed;
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _saving = true);
    final draft = _buildDraft(validateFields: true);
    if (draft == null) {
      if (mounted) setState(() => _saving = false);
      return;
    }
    final originConfirmed = await _confirmOriginSecretTransfer(draft);
    if (!mounted || !originConfirmed) {
      if (mounted) setState(() => _saving = false);
      return;
    }
    try {
      await ref
          .read(directConnectionProfilesProvider.notifier)
          .upsert(
            draft,
            expectedPrevious: _savedProfile,
            secretsConfirmedForNewOrigin:
                !_originChanged ||
                !_savedHasOriginBoundSecrets ||
                _originSecretsConfirmed,
          );
      if (!mounted) return;
      context.pop(true);
    } on DirectConnectionProfileConflictException {
      if (!mounted) return;
      final message = AppLocalizations.of(
        context,
      )!.directConnectionSaveConflict;
      setState(() {
        _saving = false;
        _formError = message;
      });
      AdaptiveSnackBar.show(
        context,
        message: message,
        type: AdaptiveSnackBarType.error,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      AdaptiveSnackBar.show(
        context,
        message: AppLocalizations.of(context)!.directConnectionSaveFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  Future<void> _testConnection() async {
    if (_busy) return;
    setState(() => _testing = true);
    final draft = _buildDraft(validateFields: true);
    if (draft == null) {
      if (mounted) setState(() => _testing = false);
      return;
    }
    final originConfirmed = await _confirmOriginSecretTransfer(draft);
    if (!mounted || !originConfirmed) {
      if (mounted) setState(() => _testing = false);
      return;
    }
    setState(() {
      _testSucceeded = null;
      _testMessage = null;
    });
    try {
      final result = await ref
          .read(directConnectionProfilesProvider.notifier)
          .probe(draft);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testSucceeded = result.reachable;
        _testMessage = _probeMessage(result, AppLocalizations.of(context)!);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testSucceeded = false;
        _testMessage = AppLocalizations.of(
          context,
        )!.directConnectionReachFailed;
      });
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final saved = _savedProfile;
    if (saved == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _deleting = true);
    try {
      final confirmed = await ThemedDialogs.confirm(
        context,
        title: l10n.directConnectionDeleteTitle,
        message: l10n.directConnectionDeleteMessage(saved.name),
        confirmText: l10n.delete,
        isDestructive: true,
      );
      if (!confirmed || !mounted) {
        if (mounted) setState(() => _deleting = false);
        return;
      }
      // Another editor can update the provider while confirmation is open.
      final currentProfiles = ref
          .read(directConnectionProfilesProvider)
          .requireValue;
      final hasAnotherUsable = currentProfiles.any(
        (profile) => profile.id != saved.id && profile.isUsable,
      );
      final profilesController = ref.read(
        directConnectionProfilesProvider.notifier,
      );
      final preferredBackendController = ref.read(
        preferredBackendProvider.notifier,
      );
      final clearDirectPreference =
          !hasAnotherUsable &&
          ref.read(preferredBackendProvider) == PreferredBackend.direct;
      var clearedDirectPreference = false;
      if (clearDirectPreference) {
        try {
          await preferredBackendController.set(PreferredBackend.unset);
          clearedDirectPreference = true;
        } catch (error) {
          DebugLogger.error(
            'Failed to clear the direct backend before profile deletion',
            scope: 'direct/editor',
            data: {'errorType': error.runtimeType.toString()},
          );
          rethrow;
        }
      }
      try {
        await profilesController.remove(saved.id);
      } catch (error, stackTrace) {
        if (clearedDirectPreference) {
          try {
            await preferredBackendController.set(PreferredBackend.direct);
          } catch (restoreError) {
            DebugLogger.error(
              'Failed to restore the direct backend after profile deletion failed',
              scope: 'direct/editor',
              data: {'errorType': restoreError.runtimeType.toString()},
            );
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (!mounted) return;
      context.pop(true);
    } catch (error) {
      DebugLogger.error(
        'Direct profile deletion failed',
        scope: 'direct/editor',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (!mounted) return;
      setState(() => _deleting = false);
      AdaptiveSnackBar.show(
        context,
        message: l10n.directConnectionDeleteFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(directConnectionProfilesProvider);
    return profiles.when(
      loading: () => _buildEditorScaffold(
        title: widget.isNew ? 'Add connection' : 'Edit connection',
        children: const [
          SizedBox(height: Spacing.xxl),
          Center(child: CircularProgressIndicator.adaptive()),
        ],
        bottomAction: ConduitButton(
          text: AppLocalizations.of(context)!.save,
          isFullWidth: true,
          isLoading: true,
          useNativeLabel: true,
        ),
      ),
      error: (_, _) => _buildEditorScaffold(
        title: widget.isNew ? 'Add connection' : 'Edit connection',
        children: [
          DirectConnectionEditorError(
            onRetry: () =>
                ref.read(directConnectionProfilesProvider.notifier).reload(),
          ),
        ],
      ),
      data: (items) {
        final profile = _profileById(items);
        if (!widget.isNew && profile == null) {
          return _buildEditorScaffold(
            title: 'Edit connection',
            children: const [
              SizedBox(height: Spacing.xl),
              Center(child: Text('This connection no longer exists.')),
            ],
          );
        }
        _hydrate(profile);
        return _buildForm(context);
      },
    );
  }

  Widget _buildEditorScaffold({
    required String title,
    required List<Widget> children,
    Widget bottomAction = const SizedBox.shrink(),
  }) {
    if (widget.isOnboarding) {
      final l10n = AppLocalizations.of(context)!;
      return AdaptiveAuthScaffold(
        title: title,
        backLabel: l10n.back,
        backButtonKey: const ValueKey<String>('direct-editor-back-button'),
        onBack: () => context.goNamed(
          RouteNames.directConnections,
          queryParameters: const {'onboarding': 'true'},
        ),
        bottomAction: bottomAction,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    }

    return SettingsPageScaffold(title: title, children: children);
  }

  Widget _buildForm(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final isOllama = _adapterKey == kOllamaAdapterKey;
    final usesCupertinoChrome = context.usesCupertinoChrome;

    final content = <Widget>[
      ConduitCard(
        onTap: () => setState(() => _enabled = !_enabled),
        padding: const EdgeInsets.all(Spacing.lg),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enabled',
                    style: theme.bodyMedium?.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    'Show models from this connection in the model picker.',
                    style: theme.bodySmall?.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.md),
            AdaptiveSwitch(
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
          ],
        ),
      ),
      const SizedBox(height: Spacing.lg),
      const SettingsSectionHeader(title: 'Provider'),
      const SizedBox(height: Spacing.sm),
      AdaptiveSegmentedSelector<String>(
        value: _adapterKey,
        showIcons: false,
        onChanged: (value) {
          setState(() {
            _adapterKey = value;
            _testSucceeded = null;
            _testMessage = null;
            if (widget.isNew) {
              _baseUrlController.text = value == kOllamaAdapterKey
                  ? ''
                  : 'https://api.openai.com/v1';
              _authentication = value == kOllamaAdapterKey
                  ? DirectAuthenticationMode.none
                  : DirectAuthenticationMode.bearer;
            }
          });
        },
        options: [
          (
            value: kOpenAiCompatibleAdapterKey,
            label: l10n.openAICompatible,
            cupertinoIcon: CupertinoIcons.cloud,
            materialIcon: Icons.cloud_outlined,
            enabled: true,
          ),
          (
            value: kOllamaAdapterKey,
            label: l10n.ollama,
            cupertinoIcon: CupertinoIcons.desktopcomputer,
            materialIcon: Icons.computer_outlined,
            enabled: true,
          ),
        ],
      ),
      const SizedBox(height: Spacing.lg),
      AccessibleFormField(
        key: const ValueKey<String>('direct-connection-name-field'),
        label: l10n.directConnectionName,
        hint: isOllama ? 'Home Ollama' : 'My provider',
        controller: _nameController,
        errorText: _nameError,
        isRequired: true,
        textInputAction: TextInputAction.next,
        onChanged: (_) => _clearTransientState(),
      ),
      const SizedBox(height: Spacing.md),
      AccessibleFormField(
        key: const ValueKey<String>('direct-base-url-field'),
        label: l10n.directApiBaseUrl,
        hint: isOllama
            ? 'http://192.168.1.10:11434'
            : 'https://api.openai.com/v1',
        controller: _baseUrlController,
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
            ? 'Use the Ollama server root. Conduit calls its native /api endpoints.'
            : 'Include the API prefix expected by the provider, usually /v1.',
        style: theme.bodySmall?.copyWith(color: theme.textSecondary),
      ),
      if (!isOllama) ...[
        const SizedBox(height: Spacing.lg),
        SettingsSectionHeader(title: l10n.directCompletionApi),
        const SizedBox(height: Spacing.sm),
        AdaptiveSegmentedSelector<DirectOpenAiApiMode>(
          key: const ValueKey<String>('direct-openai-api-mode-selector'),
          value: _openAiApiMode,
          showIcons: false,
          onChanged: (value) => setState(() {
            _openAiApiMode = value;
            _testSucceeded = null;
            _testMessage = null;
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
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.md),
        AccessibleFormField(
          key: const ValueKey<String>('direct-api-version-field'),
          label: l10n.directApiVersion,
          hint: '2024-10-21',
          controller: _apiVersionController,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          onChanged: (_) => _clearTransientState(),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          l10n.directApiVersionDescription,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
      ],
      const SizedBox(height: Spacing.lg),
      SettingsSectionHeader(title: l10n.directAuthentication),
      const SizedBox(height: Spacing.sm),
      AdaptiveSegmentedSelector<DirectAuthenticationMode>(
        value: _authentication,
        showIcons: false,
        onChanged: (value) => setState(() {
          _authentication = value;
          _apiKeyDirty = true;
          _originSecretsConfirmed = false;
          _apiKeyError = null;
          _testSucceeded = null;
          _testMessage = null;
        }),
        options: [
          (
            value: DirectAuthenticationMode.bearer,
            label: l10n.bearerToken,
            cupertinoIcon: CupertinoIcons.lock,
            materialIcon: Icons.key_outlined,
            enabled: true,
          ),
          (
            value: DirectAuthenticationMode.apiKeyHeader,
            label: l10n.directApiKeyHeader,
            cupertinoIcon: CupertinoIcons.lock_shield,
            materialIcon: Icons.vpn_key_outlined,
            enabled: true,
          ),
          (
            value: DirectAuthenticationMode.none,
            label: l10n.noAuthentication,
            cupertinoIcon: CupertinoIcons.lock_open,
            materialIcon: Icons.lock_open_outlined,
            enabled: true,
          ),
        ],
      ),
      if (_authentication == DirectAuthenticationMode.apiKeyHeader) ...[
        const SizedBox(height: Spacing.sm),
        Text(
          l10n.directApiKeyHeaderDescription,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
      ],
      if (_authentication != DirectAuthenticationMode.none) ...[
        const SizedBox(height: Spacing.md),
        AccessibleFormField(
          key: const ValueKey<String>('direct-api-key-field'),
          label: l10n.directApiKey,
          hint: (_savedProfile?.apiKey ?? '').isNotEmpty
              ? 'Configured, enter to replace'
              : 'Enter API key',
          controller: _apiKeyController,
          obscureText: !_showApiKey,
          errorText: _apiKeyError,
          isRequired: true,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          suffixIcon: IconButton(
            tooltip: _showApiKey ? l10n.hidePassword : l10n.showPassword,
            onPressed: () => setState(() => _showApiKey = !_showApiKey),
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
      if (_formError != null) ...[
        const SizedBox(height: Spacing.lg),
        Container(
          key: const ValueKey<String>('direct-form-error'),
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: theme.error.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            border: Border.all(color: theme.error.withValues(alpha: 0.3)),
          ),
          child: Text(
            _formError!,
            style: theme.bodySmall?.copyWith(color: theme.error),
          ),
        ),
      ],
      const SizedBox(height: Spacing.lg),
      _buildAdvancedSettings(),
      const SizedBox(height: Spacing.lg),
      Wrap(
        spacing: Spacing.md,
        runSpacing: Spacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (!widget.isOnboarding)
            ConduitButton(
              text: l10n.save,
              icon: Icons.check,
              isLoading: _saving,
              onPressed: _testing || _deleting ? null : _save,
            ),
          ConduitButton(
            text: l10n.testDirectConnection,
            isSecondary: true,
            isLoading: _testing,
            useNativeLabel: true,
            onPressed: _saving || _deleting ? null : _testConnection,
          ),
          if (_testMessage != null)
            Text(
              _testMessage!,
              style: theme.bodySmall?.copyWith(
                color: _testSucceeded == true ? theme.success : theme.error,
              ),
            ),
        ],
      ),
      if (!widget.isNew) ...[
        const SizedBox(height: Spacing.xl),
        ConduitButton(
          text: 'Delete connection',
          icon: Icons.delete_outline,
          isDestructive: true,
          isLoading: _deleting,
          onPressed: _saving || _testing ? null : _delete,
        ),
      ],
    ];

    return _buildEditorScaffold(
      title: widget.isNew
          ? l10n.addDirectConnection
          : l10n.editDirectConnection,
      children: content,
      bottomAction: widget.isOnboarding
          ? ConduitButton(
              key: const ValueKey<String>('direct-editor-save-button'),
              text: l10n.save,
              isFullWidth: true,
              isLoading: _saving,
              useNativeLabel: true,
              onPressed: _testing || _deleting ? null : _save,
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildAdvancedSettings() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final usesCupertinoChrome = context.usesCupertinoChrome;

    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Semantics(
            button: true,
            expanded: _showAdvancedSettings,
            child: SizedBox(
              width: double.infinity,
              child: AdaptiveButton.child(
                key: const ValueKey<String>('direct-advanced-settings-toggle'),
                onPressed: () => setState(
                  () => _showAdvancedSettings = !_showAdvancedSettings,
                ),
                style: AdaptiveButtonStyle.plain,
                size: AdaptiveButtonSize.large,
                minSize: const Size(
                  TouchTarget.minimum,
                  TouchTarget.comfortable,
                ),
                padding: EdgeInsets.zero,
                borderRadius: BorderRadius.circular(AppBorderRadius.card),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                  child: Row(
                    children: [
                      Icon(
                        usesCupertinoChrome
                            ? CupertinoIcons.gear_alt
                            : Icons.tune_rounded,
                        color: theme.iconSecondary,
                        size: IconSize.medium,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          l10n.advancedSettings,
                          style: theme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: theme.textPrimary,
                          ),
                        ),
                      ),
                      if (_customHeaders.isNotEmpty) ...[
                        ConduitBadge(
                          text: '${_customHeaders.length}',
                          backgroundColor: theme.buttonPrimary.withValues(
                            alpha: 0.1,
                          ),
                          textColor: theme.buttonPrimary,
                          isCompact: true,
                        ),
                        const SizedBox(width: Spacing.sm),
                      ],
                      AnimatedRotation(
                        duration: context.motionDuration(
                          AnimationDuration.microInteraction,
                        ),
                        turns: _showAdvancedSettings ? 0.5 : 0,
                        child: Icon(
                          usesCupertinoChrome
                              ? CupertinoIcons.chevron_down
                              : Icons.expand_more,
                          color: theme.iconSecondary,
                          size: IconSize.medium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (context.reduceMotion)
            if (_showAdvancedSettings)
              _buildAdvancedSettingsContent()
            else
              const SizedBox.shrink()
          else
            AnimatedCrossFade(
              duration: AnimationDuration.microInteraction,
              sizeCurve: Curves.easeOutCubic,
              crossFadeState: _showAdvancedSettings
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: _buildAdvancedSettingsContent(),
            ),
        ],
      ),
    );
  }

  Widget _buildAdvancedSettingsContent() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final usesCupertinoChrome = context.usesCupertinoChrome;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(
          height: BorderWidth.thin,
          thickness: BorderWidth.thin,
          color: theme.cardBorder,
        ),
        Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
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
                  if (_customHeaders.isNotEmpty)
                    Text(
                      '${_customHeaders.length}',
                      style: theme.bodySmall?.copyWith(
                        color: theme.textTertiary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              AccessibleFormField(
                key: const ValueKey<String>('direct-custom-header-name-field'),
                label: l10n.headerName,
                hint: 'X-Custom-Header',
                controller: _headerNameController,
                errorText: _headersError,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                onChanged: (_) => setState(() {
                  _headersError = null;
                  _formError = null;
                }),
                onSubmitted: (_) => _headerValueFocusNode.requestFocus(),
              ),
              const SizedBox(height: Spacing.md),
              AccessibleFormField(
                key: const ValueKey<String>('direct-custom-header-value-field'),
                label: l10n.headerValue,
                hint: l10n.headerValueHint,
                controller: _headerValueController,
                focusNode: _headerValueFocusNode,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                onChanged: (_) => setState(() {
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
                onPressed: _canAddCustomHeader
                    ? () => _addCustomHeader()
                    : null,
              ),
              if (_customHeaders.isNotEmpty) ...[
                const SizedBox(height: Spacing.md),
                for (final entry in _customHeaders.entries)
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
                controller: _modelIdPrefixController,
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
                controller: _tagsController,
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
                controller: _modelsController,
                minLines: 3,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                autocorrect: false,
                onChanged: (_) => _clearTransientState(),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                'Optional. Enter one ID per line for servers without model discovery.',
                style: theme.bodySmall?.copyWith(color: theme.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class DirectConnectionEditorError extends StatelessWidget {
  const DirectConnectionEditorError({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Column(
      children: [
        const SizedBox(height: Spacing.xl),
        Text(
          'Could not load this connection.',
          style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.md),
        ConduitButton(
          text: 'Try again',
          icon: Icons.refresh,
          onPressed: onRetry,
        ),
      ],
    );
  }
}

String _probeMessage(DirectConnectionProbe probe, AppLocalizations l10n) {
  if (!probe.reachable) {
    return probe.message?.trim().isNotEmpty == true
        ? probe.message!.trim()
        : l10n.directConnectionReachFailed;
  }
  final modelCount = probe.modelCount;
  if (modelCount == null) return l10n.directConnectionProbeConnected;
  return l10n.directConnectionProbeConnectedModels(modelCount);
}
