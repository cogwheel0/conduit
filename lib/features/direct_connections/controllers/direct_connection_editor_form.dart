import 'package:flutter/widgets.dart';

import '../models/direct_connection_profile.dart';
import '../models/openwebui_direct_connection.dart';
import 'direct_connection_editor_draft.dart';
import 'direct_custom_headers_controller.dart';

/// Owns editable direct-connection fields, draft validation, and presentation
/// preferences. Persistence and operation state belong to the workflow.
final class DirectConnectionEditorForm extends ChangeNotifier {
  DirectConnectionEditorForm({required this.mode}) {
    headers = DirectCustomHeadersController(onChanged: _handleHeaderChanged);
    name.addListener(_generalTextChanged);
    baseUrl.addListener(_baseUrlTextChanged);
    apiKey.addListener(_apiKeyTextChanged);
    apiVersion.addListener(_generalTextChanged);
    modelIdPrefix.addListener(_generalTextChanged);
    tags.addListener(_generalTextChanged);
    models.addListener(_generalTextChanged);
  }

  final DirectConnectionEditorMode mode;
  final _DraftChangeNotifier _draftChanges = _DraftChangeNotifier();

  late final DirectCustomHeadersController headers;

  final name = TextEditingController();
  final baseUrl = TextEditingController();
  final apiKey = TextEditingController();
  final apiVersion = TextEditingController();
  final modelIdPrefix = TextEditingController();
  final tags = TextEditingController();
  final models = TextEditingController();

  DirectConnectionProfile? _savedProfile;
  OpenWebUiDirectConnectionRecord? _savedOpenWebUiRecord;
  String _adapterKey = kOpenAiCompatibleAdapterKey;
  String _providerPreset = kOpenAiCompatibleAdapterKey;
  DirectOpenAiApiMode _openAiApiMode = DirectOpenAiApiMode.chatCompletions;
  DirectAuthenticationMode _authentication = DirectAuthenticationMode.bearer;
  bool _enabled = true;
  bool _apiKeyDirty = false;
  bool _showApiKey = false;
  bool _showAdvancedSettings = false;
  bool _originSecretsConfirmed = false;
  bool _updatingTextFields = false;
  DirectDraftErrors _errors = const DirectDraftErrors();

  TextEditingController get headerName => headers.name;
  TextEditingController get headerValue => headers.value;
  FocusNode get headerValueFocusNode => headers.valueFocusNode;
  Map<String, String> get customHeaders => headers.headers;
  DirectConnectionProfile? get savedProfile => _savedProfile;
  OpenWebUiDirectConnectionRecord? get savedOpenWebUiRecord =>
      _savedOpenWebUiRecord;
  String get adapterKey => _adapterKey;
  String get providerPreset => _providerPreset;
  DirectOpenAiApiMode get openAiApiMode => _openAiApiMode;
  DirectAuthenticationMode get authentication => _authentication;
  bool get enabled => _enabled;
  bool get apiKeyDirty => _apiKeyDirty;
  bool get showApiKey => _showApiKey;
  bool get showAdvancedSettings => _showAdvancedSettings;
  bool get originSecretsConfirmed => _originSecretsConfirmed;
  DirectDraftErrors get errors => _errors;
  DirectHeaderValidationError? get headerError => headers.error;
  bool get isOllama => adapterKey == kOllamaAdapterKey;
  bool get isOpenRouter => providerPreset == kOpenRouterProviderPreset;
  bool get isOpenWebUi => mode.isOpenWebUi;
  bool get canAddCustomHeader => headerName.text.trim().isNotEmpty;

  void addDraftListener(VoidCallback listener) =>
      _draftChanges.addListener(listener);

  void removeDraftListener(VoidCallback listener) =>
      _draftChanges.removeListener(listener);

  bool get originChanged {
    final saved = savedProfile;
    if (saved == null) return false;
    return DirectConnectionProfile.originOf(saved.baseUrl) !=
        DirectConnectionProfile.originOf(baseUrl.text);
  }

  bool get savedHasOriginBoundSecrets {
    final saved = savedProfile;
    return saved != null &&
        ((saved.apiKey?.isNotEmpty ?? false) || saved.customHeaders.isNotEmpty);
  }

  bool get originBoundSecretsReviewed {
    final saved = savedProfile;
    if (saved == null || !originChanged) return true;
    final apiKeyReviewed = !(saved.apiKey?.isNotEmpty ?? false) || apiKeyDirty;
    final headersReviewed = saved.customHeaders.isEmpty || headers.isDirty;
    return apiKeyReviewed && headersReviewed;
  }

  bool get apiKeyRequired => requiresDirectApiKey(
    authentication: authentication,
    mode: mode,
    savedOpenWebUiAuthType: savedOpenWebUiRecord?.authType,
    apiKeyDirty: apiKeyDirty,
    originChanged: originChanged,
  );

  void hydrate(
    DirectConnectionProfile? profile, {
    OpenWebUiDirectConnectionRecord? openWebUiRecord,
  }) {
    _updateTextFields(() {
      _savedProfile = profile;
      _savedOpenWebUiRecord = openWebUiRecord;
      if (profile == null) {
        name.text = 'My provider';
        baseUrl.text = 'https://api.openai.com/v1';
        return;
      }
      name.text = profile.name;
      baseUrl.text = profile.baseUrl;
      headers.hydrate(profile.customHeaders);
      models.text = profile.manualModelIds.join('\n');
      apiVersion.text = profile.apiVersion ?? '';
      modelIdPrefix.text = profile.modelIdPrefix ?? '';
      tags.text = profile.tags.join(', ');
      _adapterKey = profile.adapterKey;
      _providerPreset = profile.isOpenRouter
          ? kOpenRouterProviderPreset
          : profile.adapterKey;
      _openAiApiMode = profile.openAiApiMode;
      _authentication = openWebUiRecord == null
          ? profile.isOpenRouter
                ? DirectAuthenticationMode.bearer
                : (profile.apiKey ?? '').isEmpty
                ? DirectAuthenticationMode.none
                : switch (profile.apiKeyAuthMode) {
                    DirectApiKeyAuthMode.bearer =>
                      DirectAuthenticationMode.bearer,
                    DirectApiKeyAuthMode.apiKeyHeader =>
                      DirectAuthenticationMode.apiKeyHeader,
                  }
          : switch (openWebUiRecord.authType) {
              'bearer' => DirectAuthenticationMode.bearer,
              'none' => DirectAuthenticationMode.none,
              _ => DirectAuthenticationMode.unsupported,
            };
      _enabled = profile.enabled;
    });
  }

  void refreshOpenWebUiRecord(OpenWebUiDirectConnectionRecord? record) {
    final savedRecord = savedOpenWebUiRecord;
    if (record == null ||
        savedRecord == null ||
        savedRecord.profile.id != record.profile.id ||
        savedRecord.contentRevision != record.contentRevision) {
      return;
    }
    _savedOpenWebUiRecord = record;
    _savedProfile = record.profile;
  }

  void setEnabled(bool value) {
    if (enabled == value) return;
    _enabled = value;
    _draftChanged();
  }

  void selectProviderPreset(
    String value, {
    required String ollamaDefaultName,
    required String openRouterDefaultName,
  }) {
    if (providerPreset == value) return;
    _providerPreset = value;
    _adapterKey = value == kOllamaAdapterKey
        ? kOllamaAdapterKey
        : kOpenAiCompatibleAdapterKey;
    _authentication = DirectAuthenticationMode.bearer;
    _openAiApiMode = DirectOpenAiApiMode.chatCompletions;
    _updateTextFields(() {
      baseUrl.text = switch (value) {
        kOllamaAdapterKey => 'https://ollama.com',
        kOpenRouterProviderPreset => kOpenRouterApiBaseUrl,
        _ => 'https://api.openai.com/v1',
      };
      if (mode.isNew &&
          (name.text == 'My provider' ||
              name.text == ollamaDefaultName ||
              name.text == openRouterDefaultName)) {
        name.text = switch (value) {
          kOllamaAdapterKey => ollamaDefaultName,
          kOpenRouterProviderPreset => openRouterDefaultName,
          _ => 'My provider',
        };
      }
    });
    _originSecretsConfirmed = false;
    _draftChanged();
  }

  void setAuthentication(DirectAuthenticationMode value) {
    if (authentication == value ||
        value == DirectAuthenticationMode.unsupported) {
      return;
    }
    _authentication = value;
    _apiKeyDirty = true;
    _originSecretsConfirmed = false;
    _errors = errors.copyWith(clearApiKey: true, clearForm: true);
    _draftChanged();
  }

  void setOpenAiApiMode(DirectOpenAiApiMode value) {
    if (openAiApiMode == value) return;
    _openAiApiMode = value;
    _draftChanged();
  }

  void setShowApiKey(bool value) {
    if (showApiKey == value) return;
    _showApiKey = value;
    notifyListeners();
  }

  void setShowAdvancedSettings(bool value) {
    if (showAdvancedSettings == value) return;
    _showAdvancedSettings = value;
    notifyListeners();
  }

  bool commitPendingCustomHeader() {
    final committed = headers.commitPending();
    if (!committed) _revealAdvancedSettings();
    return committed;
  }

  bool addCustomHeader() {
    final added = headers.add();
    if (!added && headers.error != null) _revealAdvancedSettings();
    return added;
  }

  void removeCustomHeader(String name) => headers.remove(name);

  DirectDraftBuildResult buildDraft({
    required bool validateFields,
    required String openWebUiFallbackName,
  }) {
    if (validateFields && !commitPendingCustomHeader()) {
      return DirectDraftBuildResult(errors: errors);
    }
    final draft = DirectConnectionDraft(
      mode: mode,
      savedProfile: savedProfile,
      savedOpenWebUiAuthType: savedOpenWebUiRecord?.authType,
      adapterKey: adapterKey,
      providerPreset: providerPreset,
      openAiApiMode: openAiApiMode,
      authentication: authentication,
      enabled: enabled,
      apiKeyDirty: apiKeyDirty,
      originBoundSecretsReviewed: originBoundSecretsReviewed,
      name: name.text,
      baseUrl: baseUrl.text,
      apiKey: apiKey.text,
      apiVersion: apiVersion.text,
      modelIdPrefix: modelIdPrefix.text,
      tags: tags.text,
      models: models.text,
      customHeaders: customHeaders,
    );
    final result = draft.build(openWebUiFallbackName: openWebUiFallbackName);
    _errors = result.errors;
    if (validateFields && errors.hasAny) notifyListeners();
    return result;
  }

  void confirmOriginSecrets() {
    if (originSecretsConfirmed) return;
    _originSecretsConfirmed = true;
    notifyListeners();
  }

  void _generalTextChanged() {
    if (_updatingTextFields) return;
    _errors = const DirectDraftErrors();
    headers.clearError();
    _draftChanged();
  }

  void _baseUrlTextChanged() {
    if (_updatingTextFields) return;
    _originSecretsConfirmed = false;
    _generalTextChanged();
  }

  void _apiKeyTextChanged() {
    if (_updatingTextFields) return;
    _apiKeyDirty = true;
    _originSecretsConfirmed = false;
    _errors = errors.copyWith(clearApiKey: true, clearForm: true);
    _draftChanged();
  }

  void _handleHeaderChanged(DirectCustomHeadersChange change) {
    if (change == DirectCustomHeadersChange.collection) {
      _originSecretsConfirmed = false;
    }
    _errors = errors.copyWith(clearForm: true);
    _draftChanged();
  }

  void _revealAdvancedSettings() {
    if (showAdvancedSettings) return;
    _showAdvancedSettings = true;
    notifyListeners();
  }

  void _draftChanged() {
    _draftChanges.notify();
    notifyListeners();
  }

  void _updateTextFields(VoidCallback update) {
    _updatingTextFields = true;
    try {
      update();
    } finally {
      _updatingTextFields = false;
    }
  }

  @override
  void dispose() {
    name.removeListener(_generalTextChanged);
    baseUrl.removeListener(_baseUrlTextChanged);
    apiKey.removeListener(_apiKeyTextChanged);
    apiVersion.removeListener(_generalTextChanged);
    modelIdPrefix.removeListener(_generalTextChanged);
    tags.removeListener(_generalTextChanged);
    models.removeListener(_generalTextChanged);
    name.dispose();
    baseUrl.dispose();
    apiKey.dispose();
    apiVersion.dispose();
    modelIdPrefix.dispose();
    tags.dispose();
    models.dispose();
    headers.dispose();
    _draftChanges.dispose();
    super.dispose();
  }
}

final class _DraftChangeNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
