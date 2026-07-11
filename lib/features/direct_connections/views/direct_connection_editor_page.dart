import 'dart:convert';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../profile/widgets/adaptive_segmented_selector.dart';
import '../../profile/widgets/customization_tile.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../providers/direct_connection_providers.dart';

enum DirectAuthenticationMode { bearer, none }

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
  final _headersController = TextEditingController();
  final _modelsController = TextEditingController();

  DirectConnectionProfile? _savedProfile;
  String _adapterKey = kOpenAiCompatibleAdapterKey;
  DirectAuthenticationMode _authentication = DirectAuthenticationMode.bearer;
  bool _enabled = true;
  bool _hydrated = false;
  bool _apiKeyDirty = false;
  bool _headersDirty = false;
  bool _showApiKey = false;
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

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _headersController.dispose();
    _modelsController.dispose();
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
    _headersController.text = profile.customHeaders.isEmpty
        ? ''
        : const JsonEncoder.withIndent('  ').convert(profile.customHeaders);
    _modelsController.text = profile.manualModelIds.join('\n');
    _adapterKey = profile.adapterKey;
    _authentication = (profile.apiKey ?? '').isEmpty
        ? DirectAuthenticationMode.none
        : DirectAuthenticationMode.bearer;
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

  bool get _originBoundSecretsReviewed {
    final saved = _savedProfile;
    if (saved == null || !_originChanged) return true;
    final apiKeyReviewed = !(saved.apiKey?.isNotEmpty ?? false) || _apiKeyDirty;
    final headersReviewed = saved.customHeaders.isEmpty || _headersDirty;
    return apiKeyReviewed && headersReviewed;
  }

  DirectConnectionProfile? _buildDraft({required bool validateFields}) {
    final name = _nameController.text.trim();
    final baseUrl = normalizeDirectBaseUrl(_baseUrlController.text);
    var valid = true;

    String? nameError;
    String? urlError;
    String? apiKeyError;
    String? headersError;

    if (name.isEmpty) {
      valid = false;
      nameError = 'Enter a connection name.';
    }
    if (DirectConnectionProfile.originOf(baseUrl) == null) {
      valid = false;
      urlError = 'Use a valid http:// or https:// URL.';
    } else if (!_originBoundSecretsReviewed) {
      valid = false;
      urlError = 'Re-enter credentials when changing servers.';
    }

    final existingApiKey = _savedProfile?.apiKey?.trim() ?? '';
    final enteredApiKey = _apiKeyController.text.trim();
    final apiKey = switch (_authentication) {
      DirectAuthenticationMode.none => null,
      DirectAuthenticationMode.bearer =>
        _apiKeyDirty || _originChanged ? enteredApiKey : existingApiKey,
    };
    if (_authentication == DirectAuthenticationMode.bearer &&
        (apiKey ?? '').isEmpty) {
      valid = false;
      apiKeyError = 'Enter an API key or choose no authentication.';
    }

    Map<String, String> headers = const {};
    try {
      headers = parseDirectCustomHeaders(_headersController.text);
    } on FormatException catch (error) {
      valid = false;
      headersError = error.message.toString();
    }

    if (validateFields) {
      setState(() {
        _nameError = nameError;
        _urlError = urlError;
        _apiKeyError = apiKeyError;
        _headersError = headersError;
      });
    }
    if (!valid) return null;

    final saved = _savedProfile;
    final profile = DirectConnectionProfile(
      id: saved?.id ?? const Uuid().v4(),
      name: name,
      adapterKey: _adapterKey,
      baseUrl: baseUrl,
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
      if (validateFields) setState(() => _headersError = profileError);
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
      _testSucceeded = null;
      _testMessage = null;
    });
  }

  void _invalidateOriginSecretConfirmation() {
    _originSecretsConfirmed = false;
    _clearTransientState();
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
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: 'Use credentials with new server?',
      message:
          'This sends the API key and complete custom-header map to the new server. Only continue if you trust it.',
      confirmText: 'Use credentials',
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
            secretsConfirmedForNewOrigin:
                !_originChanged ||
                !_savedHasOriginBoundSecrets ||
                _originSecretsConfirmed,
          );
      if (!mounted) return;
      context.pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _headersError = 'Could not save this connection.';
        _saving = false;
      });
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
        _testMessage = _probeMessage(result);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testSucceeded = false;
        _testMessage = 'Could not reach the provider.';
      });
    }
  }

  Future<void> _delete(List<DirectConnectionProfile> profiles) async {
    if (_busy) return;
    final saved = _savedProfile;
    if (saved == null) return;
    setState(() => _deleting = true);
    try {
      final confirmed = await ThemedDialogs.confirm(
        context,
        title: 'Delete connection?',
        message:
            'This removes ${saved.name} and its credentials from this device.',
        confirmText: 'Delete',
        isDestructive: true,
      );
      if (!confirmed || !mounted) {
        if (mounted) setState(() => _deleting = false);
        return;
      }
      final hasAnotherUsable = profiles.any(
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
        } catch (error, stackTrace) {
          DebugLogger.error(
            'Failed to clear the direct backend before profile deletion',
            scope: 'direct/editor',
            error: error,
            stackTrace: stackTrace,
            data: {'profileId': saved.id},
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
          } catch (restoreError, restoreStackTrace) {
            DebugLogger.error(
              'Failed to restore the direct backend after profile deletion failed',
              scope: 'direct/editor',
              error: restoreError,
              stackTrace: restoreStackTrace,
              data: {'profileId': saved.id},
            );
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (!mounted) return;
      context.pop(true);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'Direct profile deletion failed',
        scope: 'direct/editor',
        error: error,
        stackTrace: stackTrace,
        data: {'profileId': saved.id},
      );
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _headersError = 'Could not delete this connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(directConnectionProfilesProvider);
    return profiles.when(
      loading: () => SettingsPageScaffold(
        title: widget.isNew ? 'Add connection' : 'Edit connection',
        children: const [
          SizedBox(height: Spacing.xxl),
          Center(child: CircularProgressIndicator.adaptive()),
        ],
      ),
      error: (_, _) => SettingsPageScaffold(
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
          return SettingsPageScaffold(
            title: 'Edit connection',
            children: const [
              SizedBox(height: Spacing.xl),
              Center(child: Text('This connection no longer exists.')),
            ],
          );
        }
        _hydrate(profile);
        return _buildForm(context, items);
      },
    );
  }

  Widget _buildForm(
    BuildContext context,
    List<DirectConnectionProfile> profiles,
  ) {
    final theme = context.conduitTheme;
    final isOllama = _adapterKey == kOllamaAdapterKey;

    return SettingsPageScaffold(
      title: widget.isNew ? 'Add connection' : 'Edit connection',
      children: [
        CustomizationTile(
          leading: SettingsIconBadge(
            icon: Icons.power_settings_new,
            color: _enabled ? theme.buttonPrimary : theme.iconSecondary,
          ),
          title: 'Enabled',
          subtitle: 'Show models from this connection in the model picker.',
          trailing: AdaptiveSwitch(
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          onTap: () => setState(() => _enabled = !_enabled),
          showChevron: false,
        ),
        const SizedBox(height: Spacing.lg),
        const SettingsSectionHeader(title: 'Provider'),
        const SizedBox(height: Spacing.sm),
        AdaptiveSegmentedSelector<String>(
          value: _adapterKey,
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
          options: const [
            (
              value: kOpenAiCompatibleAdapterKey,
              label: 'OpenAI API',
              cupertinoIcon: CupertinoIcons.cloud,
              materialIcon: Icons.cloud_outlined,
              enabled: true,
            ),
            (
              value: kOllamaAdapterKey,
              label: 'Ollama',
              cupertinoIcon: CupertinoIcons.desktopcomputer,
              materialIcon: Icons.computer_outlined,
              enabled: true,
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        ConduitInput(
          label: 'Connection name',
          hint: isOllama ? 'Home Ollama' : 'My provider',
          controller: _nameController,
          errorText: _nameError,
          isRequired: true,
          onChanged: (_) => _clearTransientState(),
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          label: 'Base URL',
          hint: isOllama
              ? 'http://192.168.1.10:11434'
              : 'https://api.openai.com/v1',
          controller: _baseUrlController,
          keyboardType: TextInputType.url,
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
        const SizedBox(height: Spacing.lg),
        const SettingsSectionHeader(title: 'Authentication'),
        const SizedBox(height: Spacing.sm),
        AdaptiveSegmentedSelector<DirectAuthenticationMode>(
          value: _authentication,
          onChanged: (value) => setState(() {
            _authentication = value;
            _apiKeyDirty = true;
            _originSecretsConfirmed = false;
            _apiKeyError = null;
            _testSucceeded = null;
            _testMessage = null;
          }),
          options: const [
            (
              value: DirectAuthenticationMode.bearer,
              label: 'Bearer',
              cupertinoIcon: CupertinoIcons.lock,
              materialIcon: Icons.key_outlined,
              enabled: true,
            ),
            (
              value: DirectAuthenticationMode.none,
              label: 'No auth',
              cupertinoIcon: CupertinoIcons.lock_open,
              materialIcon: Icons.lock_open_outlined,
              enabled: true,
            ),
          ],
        ),
        if (_authentication == DirectAuthenticationMode.bearer) ...[
          const SizedBox(height: Spacing.md),
          ConduitInput(
            label: 'API key',
            hint: (_savedProfile?.apiKey ?? '').isNotEmpty
                ? 'Configured, enter to replace'
                : 'Enter API key',
            controller: _apiKeyController,
            obscureText: !_showApiKey,
            errorText: _apiKeyError,
            isRequired: true,
            suffixIcon: IconButton(
              tooltip: _showApiKey ? 'Hide API key' : 'Show API key',
              onPressed: () => setState(() => _showApiKey = !_showApiKey),
              icon: Icon(_showApiKey ? Icons.visibility_off : Icons.visibility),
            ),
            onChanged: (_) {
              _apiKeyDirty = true;
              _invalidateOriginSecretConfirmation();
            },
          ),
        ],
        const SizedBox(height: Spacing.lg),
        ConduitInput(
          label: 'Custom headers',
          hint: '{\n  "X-Organization": "example"\n}',
          controller: _headersController,
          minLines: 3,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          errorText: _headersError,
          onChanged: (_) {
            _headersDirty = true;
            _invalidateOriginSecretConfirmation();
          },
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'Optional JSON object. Authorization, Host, and Content-Length are reserved.',
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          label: 'Manual model IDs',
          hint: 'model-a\nmodel-b',
          controller: _modelsController,
          minLines: 3,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          onChanged: (_) => _clearTransientState(),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'Optional. Enter one ID per line for servers without model discovery.',
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.lg),
        Wrap(
          spacing: Spacing.md,
          runSpacing: Spacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConduitButton(
              text: 'Save',
              icon: Icons.check,
              isLoading: _saving,
              onPressed: _testing || _deleting ? null : _save,
            ),
            ConduitButton(
              text: 'Test connection',
              icon: Icons.wifi_tethering,
              isSecondary: true,
              isLoading: _testing,
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
            onPressed: _saving || _testing ? null : () => _delete(profiles),
          ),
        ],
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

String _probeMessage(DirectConnectionProbe probe) {
  if (!probe.reachable) {
    return probe.message?.trim().isNotEmpty == true
        ? probe.message!.trim()
        : 'Could not reach the provider.';
  }
  final modelCount = probe.modelCount;
  if (modelCount == null) return 'Connected';
  return modelCount == 1
      ? 'Connected · 1 model'
      : 'Connected · $modelCount models';
}
