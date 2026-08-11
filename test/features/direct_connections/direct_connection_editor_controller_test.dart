import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_controller.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('draft controller owns provider transitions and profile creation', () {
    final controller = DirectConnectionEditorController(
      isOpenWebUi: false,
      isNew: true,
      gateway: _FakeDirectConnectionEditorGateway(),
    );
    addTearDown(controller.dispose);
    controller.hydrate(null);

    controller.selectProviderPreset(
      kOllamaAdapterKey,
      ollamaDefaultName: 'Ollama Cloud',
      openRouterDefaultName: 'OpenRouter',
    );

    check(controller.adapterKey).equals(kOllamaAdapterKey);
    check(controller.name.text).equals('Ollama Cloud');
    check(controller.baseUrl.text).equals('https://ollama.com');

    controller.setAuthentication(DirectAuthenticationMode.none);
    final result = controller.buildDraft(
      validateFields: true,
      openWebUiFallbackName: 'Open WebUI connection',
    );

    check(result.errors.hasAny).isFalse();
    check(result.profile).isNotNull();
    check(result.profile!.adapterKey).equals(kOllamaAdapterKey);
  });

  test('draft validation returns typed field issues', () {
    final controller = DirectConnectionEditorController(
      isOpenWebUi: false,
      isNew: true,
      gateway: _FakeDirectConnectionEditorGateway(),
    );
    addTearDown(controller.dispose);
    controller.hydrate(null);
    controller.name.clear();
    controller.baseUrl.text = 'not a URL';

    final result = controller.buildDraft(
      validateFields: true,
      openWebUiFallbackName: 'Open WebUI connection',
    );

    check(result.profile).isNull();
    check(result.errors.name).equals(DirectDraftValidationIssue.nameRequired);
    check(result.errors.url).equals(DirectDraftValidationIssue.invalidUrl);
    check(
      result.errors.apiKey,
    ).equals(DirectDraftValidationIssue.apiKeyRequired);
  });

  test('custom-header validation is typed and case-insensitive', () {
    final controller = DirectConnectionEditorController(
      isOpenWebUi: false,
      isNew: true,
      gateway: _FakeDirectConnectionEditorGateway(),
    );
    addTearDown(controller.dispose);

    controller.headerName.text = 'Authorization';
    check(controller.addCustomHeader()).isFalse();
    check(
      controller.headerError?.issue,
    ).equals(DirectHeaderValidationIssue.reservedName);

    controller.headerName.text = 'X-Tenant';
    controller.headerValue.text = 'one';
    check(controller.addCustomHeader()).isTrue();
    controller.headerName.text = 'x-tenant';
    controller.headerValue.text = 'two';
    check(controller.addCustomHeader()).isFalse();
    check(
      controller.headerError?.issue,
    ).equals(DirectHeaderValidationIssue.duplicateName);
  });

  test('editing pending header text does not review saved origin secrets', () {
    final controller = DirectConnectionEditorController(
      isOpenWebUi: false,
      isNew: false,
      gateway: _FakeDirectConnectionEditorGateway(),
    );
    addTearDown(controller.dispose);
    controller.hydrate(
      DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://old.example/v1',
        customHeaders: {'X-Tenant': 'secret'},
      ),
    );
    controller.baseUrl.text = 'https://new.example/v1';

    controller.headerName.text = 'X-Pending';

    check(controller.originBoundSecretsReviewed).isFalse();
  });

  test(
    'editor workflow admits one operation and resets stale feedback',
    () async {
      final probe = Completer<DirectConnectionProbe>();
      final gateway = _FakeDirectConnectionEditorGateway(
        probeHandler: (_) => probe.future,
      );
      final controller = DirectConnectionEditorController(
        isOpenWebUi: false,
        isNew: true,
        gateway: gateway,
      );
      addTearDown(controller.dispose);
      controller.hydrate(null);
      controller.setAuthentication(DirectAuthenticationMode.none);

      final testFuture = controller.testConnection(
        messages: _messages,
        confirmCredentialTransfer: (_) async => true,
        ownerIsCurrent: () => true,
      );
      check(controller.state.operation).equals(DirectEditorOperation.testing);

      final concurrentSave = await controller.save(
        messages: _messages,
        confirmCredentialTransfer: (_) async => true,
        ownerIsCurrent: () => true,
      );
      check(concurrentSave.outcome).equals(DirectEditorActionOutcome.cancelled);

      probe.complete(const DirectConnectionProbe(reachable: false));
      final testResult = await testFuture;
      check(testResult.outcome).equals(DirectEditorActionOutcome.unreachable);
      check(controller.state.operation).equals(DirectEditorOperation.idle);
      check(controller.state.attempt.isVisible).isTrue();

      controller.name.text = 'Updated provider';
      check(controller.state.operationError).isNull();
      check(controller.state.attempt.isVisible).isFalse();
    },
  );

  test('save workflow validates and delegates persistence', () async {
    final gateway = _FakeDirectConnectionEditorGateway();
    final controller = DirectConnectionEditorController(
      isOpenWebUi: false,
      isNew: true,
      gateway: gateway,
    );
    addTearDown(controller.dispose);
    controller.hydrate(null);
    controller.setAuthentication(DirectAuthenticationMode.none);

    final result = await controller.save(
      messages: _messages,
      confirmCredentialTransfer: (_) async => true,
      ownerIsCurrent: () => true,
    );

    check(result.outcome).equals(DirectEditorActionOutcome.succeeded);
    check(gateway.savedLocal).isNotNull();
    check(gateway.savedLocal!.name).equals('My provider');
  });

  test('owner identity is captured once and includes auth epoch identity', () {
    final controller = DirectConnectionEditorController(
      isOpenWebUi: true,
      isNew: true,
      gateway: _FakeDirectConnectionEditorGateway(),
    );
    addTearDown(controller.dispose);
    final epoch = Object();

    controller.captureOwner(
      serverId: 'server',
      accountId: 'account',
      authEpoch: epoch,
    );
    controller.captureOwner(
      serverId: 'replacement',
      accountId: 'replacement',
      authEpoch: Object(),
    );

    check(
      controller.ownerMatches(
        serverId: 'server',
        accountId: 'account',
        authEpoch: epoch,
      ),
    ).isTrue();
    check(
      controller.ownerMatches(
        serverId: 'server',
        accountId: 'account',
        authEpoch: Object(),
      ),
    ).isFalse();
  });
}

const _messages = DirectEditorMessages(
  openWebUiFallbackName: 'Open WebUI connection',
  connecting: 'Connecting',
  reachFailed: 'Connection failed',
  saveConflict: 'Save conflict',
  saveFailed: 'Save failed',
  unavailable: 'Unavailable',
  probeMessage: _probeMessage,
);

String _probeMessage(DirectConnectionProbe probe) =>
    probe.reachable ? 'Connected' : 'Connection failed';

final class _FakeDirectConnectionEditorGateway
    implements DirectConnectionEditorGateway {
  _FakeDirectConnectionEditorGateway({this.probeHandler});

  final Future<DirectConnectionProbe> Function(DirectConnectionProfile)?
  probeHandler;
  DirectConnectionProfile? savedLocal;

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) =>
      probeHandler?.call(profile) ??
      Future.value(const DirectConnectionProbe(reachable: true));

  @override
  Future<void> saveLocal({
    required DirectConnectionProfile draft,
    required DirectConnectionProfile? expectedPrevious,
    required bool secretsConfirmedForNewOrigin,
  }) async {
    savedLocal = draft;
  }

  @override
  Future<void> saveOpenWebUi({
    required DirectConnectionProfile draft,
    required OpenWebUiDirectConnectionRecord? previous,
    required bool isNew,
    required String? authType,
  }) async {}

  @override
  Future<bool> clearDirectPreferenceIfLastUsable(String profileId) async =>
      false;

  @override
  Future<void> restoreDirectPreference() async {}

  @override
  Future<void> deleteLocal(String profileId) async {}

  @override
  Future<void> deleteOpenWebUi(OpenWebUiDirectConnectionRecord record) async {}
}
