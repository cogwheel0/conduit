import 'package:flutter/widgets.dart';

import '../models/direct_connection_profile.dart';
import '../models/openwebui_direct_connection.dart';
import 'direct_connection_editor_draft.dart';
import 'direct_connection_editor_form.dart';
import 'direct_connection_editor_workflow.dart';
import 'direct_custom_headers_controller.dart';

export 'direct_custom_headers_controller.dart'
    show DirectHeaderValidationError, DirectHeaderValidationIssue;
export 'direct_connection_editor_draft.dart';
export 'direct_connection_editor_workflow.dart';

/// Stable view-facing facade over independently owned form and workflow state.
final class DirectConnectionEditorController extends ChangeNotifier {
  DirectConnectionEditorController({
    required this.isOpenWebUi,
    required this.isNew,
    required this.gateway,
  }) {
    _form = DirectConnectionEditorForm(
      isOpenWebUi: isOpenWebUi,
      isNew: isNew,
      onDraftChanged: _handleDraftChanged,
    );
    _workflow = DirectConnectionEditorWorkflow(
      isOpenWebUi: isOpenWebUi,
      isNew: isNew,
      gateway: gateway,
      form: _form,
    );
    _form.addListener(_relayChange);
    _workflow.addListener(_relayChange);
  }

  final bool isOpenWebUi;
  final bool isNew;
  final DirectConnectionEditorGateway gateway;

  late final DirectConnectionEditorForm _form;
  late final DirectConnectionEditorWorkflow _workflow;

  DirectConnectionEditorState get state => _workflow.state;
  DirectCustomHeadersController get headers => _form.headers;
  TextEditingController get name => _form.name;
  TextEditingController get baseUrl => _form.baseUrl;
  TextEditingController get apiKey => _form.apiKey;
  TextEditingController get apiVersion => _form.apiVersion;
  TextEditingController get modelIdPrefix => _form.modelIdPrefix;
  TextEditingController get tags => _form.tags;
  TextEditingController get models => _form.models;
  TextEditingController get headerName => _form.headerName;
  TextEditingController get headerValue => _form.headerValue;
  FocusNode get headerValueFocusNode => _form.headerValueFocusNode;
  Map<String, String> get customHeaders => _form.customHeaders;
  DirectConnectionProfile? get savedProfile => _form.savedProfile;
  OpenWebUiDirectConnectionRecord? get savedOpenWebUiRecord =>
      _form.savedOpenWebUiRecord;
  String get adapterKey => _form.adapterKey;
  String get providerPreset => _form.providerPreset;
  DirectOpenAiApiMode get openAiApiMode => _form.openAiApiMode;
  DirectAuthenticationMode get authentication => _form.authentication;
  bool get enabled => _form.enabled;
  bool get apiKeyDirty => _form.apiKeyDirty;
  bool get showApiKey => _form.showApiKey;
  bool get showAdvancedSettings => _form.showAdvancedSettings;
  bool get originSecretsConfirmed => _form.originSecretsConfirmed;
  DirectDraftErrors get errors => _form.errors;
  DirectHeaderValidationError? get headerError => _form.headerError;
  bool get isOllama => _form.isOllama;
  bool get isOpenRouter => _form.isOpenRouter;
  bool get originChanged => _form.originChanged;
  bool get savedHasOriginBoundSecrets => _form.savedHasOriginBoundSecrets;
  bool get originBoundSecretsReviewed => _form.originBoundSecretsReviewed;
  bool get canAddCustomHeader => _form.canAddCustomHeader;
  bool get apiKeyRequired => _form.apiKeyRequired;

  void captureOwner({
    required String serverId,
    required String accountId,
    required Object authEpoch,
  }) => _workflow.captureOwner(
    serverId: serverId,
    accountId: accountId,
    authEpoch: authEpoch,
  );

  bool ownerMatches({
    required String serverId,
    required String accountId,
    required Object authEpoch,
  }) => _workflow.ownerMatches(
    serverId: serverId,
    accountId: accountId,
    authEpoch: authEpoch,
  );

  void hydrateOnce(
    DirectConnectionProfile? profile, {
    OpenWebUiDirectConnectionRecord? openWebUiRecord,
  }) {
    if (state.hydrated) return;
    _workflow.markHydrated();
    _form.hydrate(profile, openWebUiRecord: openWebUiRecord);
  }

  void hydrate(
    DirectConnectionProfile? profile, {
    OpenWebUiDirectConnectionRecord? openWebUiRecord,
  }) => _form.hydrate(profile, openWebUiRecord: openWebUiRecord);

  void refreshOpenWebUiRecord(OpenWebUiDirectConnectionRecord? record) =>
      _form.refreshOpenWebUiRecord(record);

  void setEnabled(bool value) => _form.setEnabled(value);

  void selectProviderPreset(
    String value, {
    required String ollamaDefaultName,
    required String openRouterDefaultName,
  }) => _form.selectProviderPreset(
    value,
    ollamaDefaultName: ollamaDefaultName,
    openRouterDefaultName: openRouterDefaultName,
  );

  void setAuthentication(DirectAuthenticationMode value) =>
      _form.setAuthentication(value);

  void setOpenAiApiMode(DirectOpenAiApiMode value) =>
      _form.setOpenAiApiMode(value);

  void setShowApiKey(bool value) => _form.setShowApiKey(value);

  void setShowAdvancedSettings(bool value) =>
      _form.setShowAdvancedSettings(value);

  bool commitPendingCustomHeader() => _form.commitPendingCustomHeader();

  bool addCustomHeader() => _form.addCustomHeader();

  void removeCustomHeader(String name) => _form.removeCustomHeader(name);

  DirectDraftBuildResult buildDraft({
    required bool validateFields,
    required String openWebUiFallbackName,
  }) => _form.buildDraft(
    validateFields: validateFields,
    openWebUiFallbackName: openWebUiFallbackName,
  );

  Future<DirectEditorActionResult> save({
    required DirectEditorMessages messages,
    required DirectCredentialTransferConfirmation confirmCredentialTransfer,
    required DirectEditorOwnerCheck ownerIsCurrent,
    DirectConnectionProfile? testedDraft,
  }) => _workflow.save(
    messages: messages,
    confirmCredentialTransfer: confirmCredentialTransfer,
    ownerIsCurrent: ownerIsCurrent,
    testedDraft: testedDraft,
  );

  Future<DirectEditorActionResult> testConnection({
    required DirectEditorMessages messages,
    required DirectCredentialTransferConfirmation confirmCredentialTransfer,
    required DirectEditorOwnerCheck ownerIsCurrent,
  }) => _workflow.testConnection(
    messages: messages,
    confirmCredentialTransfer: confirmCredentialTransfer,
    ownerIsCurrent: ownerIsCurrent,
  );

  Future<DirectEditorActionResult> connectAndSave({
    required DirectEditorMessages messages,
    required DirectCredentialTransferConfirmation confirmCredentialTransfer,
    required DirectEditorOwnerCheck ownerIsCurrent,
  }) => _workflow.connectAndSave(
    messages: messages,
    confirmCredentialTransfer: confirmCredentialTransfer,
    ownerIsCurrent: ownerIsCurrent,
  );

  Future<DirectEditorActionResult> delete({
    required DirectEditorMessages messages,
    required DirectDeleteConfirmation confirmDelete,
    required DirectEditorOwnerCheck ownerIsCurrent,
  }) => _workflow.delete(
    messages: messages,
    confirmDelete: confirmDelete,
    ownerIsCurrent: ownerIsCurrent,
  );

  void _handleDraftChanged() => _workflow.handleDraftChanged();

  void _relayChange() => notifyListeners();

  @override
  void dispose() {
    _form.removeListener(_relayChange);
    _workflow.removeListener(_relayChange);
    _workflow.dispose();
    _form.dispose();
    super.dispose();
  }
}
