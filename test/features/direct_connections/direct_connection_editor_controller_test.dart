import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_form.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_workflow.dart';
import 'package:conduit/features/direct_connections/controllers/direct_custom_headers_controller.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/services/direct_connection_profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('form owns provider transitions and profile creation', () {
    final editor = _EditorHarness();
    addTearDown(editor.dispose);
    editor.form.hydrate(null);

    editor.form.selectProviderPreset(
      kOllamaAdapterKey,
      ollamaDefaultName: 'Ollama Cloud',
      openRouterDefaultName: 'OpenRouter',
    );

    check(editor.form.adapterKey).equals(kOllamaAdapterKey);
    check(editor.form.name.text).equals('Ollama Cloud');
    check(editor.form.baseUrl.text).equals('https://ollama.com');

    editor.form.setAuthentication(DirectAuthenticationMode.none);
    final result = editor.form.buildDraft(
      validateFields: true,
      openWebUiFallbackName: 'Open WebUI connection',
    );

    check(result.errors.hasAny).isFalse();
    check(result.profile).isNotNull();
    check(result.profile!.adapterKey).equals(kOllamaAdapterKey);
  });

  test('draft validation returns typed field issues', () {
    final editor = _EditorHarness();
    addTearDown(editor.dispose);
    editor.form.hydrate(null);
    editor.form.name.clear();
    editor.form.baseUrl.text = 'not a URL';

    final result = editor.form.buildDraft(
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
    final editor = _EditorHarness();
    addTearDown(editor.dispose);

    editor.form.headerName.text = 'Authorization';
    check(editor.form.addCustomHeader()).isFalse();
    check(
      editor.form.headerError?.issue,
    ).equals(DirectHeaderValidationIssue.reservedName);

    editor.form.headerName.text = 'X-Tenant';
    editor.form.headerValue.text = 'one';
    check(editor.form.addCustomHeader()).isTrue();
    editor.form.headerName.text = 'x-tenant';
    editor.form.headerValue.text = 'two';
    check(editor.form.addCustomHeader()).isFalse();
    check(
      editor.form.headerError?.issue,
    ).equals(DirectHeaderValidationIssue.duplicateName);
  });

  test('custom-header validation publishes only through the owning form', () {
    final editor = _EditorHarness();
    addTearDown(editor.dispose);
    var formNotifications = 0;
    editor.form.addListener(() => formNotifications++);

    editor.form.headerName.text = 'Authorization';
    formNotifications = 0;
    check(editor.form.addCustomHeader()).isFalse();
    check(formNotifications).equals(2);
    check(editor.form.headerError).isNotNull();

    formNotifications = 0;
    editor.form.headerName.text = 'X-Tenant';
    check(editor.form.headerError).isNull();
    check(formNotifications).equals(1);
  });

  test('editing pending header text does not review saved origin secrets', () {
    final editor = _EditorHarness(isNew: false);
    addTearDown(editor.dispose);
    editor.form.hydrate(
      DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://old.example/v1',
        customHeaders: {'X-Tenant': 'secret'},
      ),
    );
    editor.form.baseUrl.text = 'https://new.example/v1';
    editor.form.headerName.text = 'X-Pending';

    check(editor.form.originBoundSecretsReviewed).isFalse();
  });

  test('adding a custom header reviews saved origin-bound headers', () {
    final editor = _EditorHarness(isNew: false);
    addTearDown(editor.dispose);
    editor.form.hydrate(
      DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://old.example/v1',
        customHeaders: {'X-Tenant': 'secret'},
      ),
    );
    editor.form.baseUrl.text = 'https://new.example/v1';
    editor.form.headerName.text = 'X-Replacement-Tenant';
    editor.form.headerValue.text = 'replacement';

    check(editor.form.originBoundSecretsReviewed).isFalse();
    check(editor.form.addCustomHeader()).isTrue();
    check(editor.form.originBoundSecretsReviewed).isTrue();
  });

  test(
    'editor workflow admits one operation and resets stale feedback',
    () async {
      final probe = Completer<DirectConnectionProbe>();
      final target = _FakeDirectConnectionEditorTarget(
        probeHandler: (_) => probe.future,
      );
      final editor = _EditorHarness(target: target);
      addTearDown(editor.dispose);
      editor.form.hydrate(null);
      editor.form.setAuthentication(DirectAuthenticationMode.none);

      final testFuture = editor.workflow.testConnection(
        messages: _messages,
        confirmCredentialTransfer: (_) async => true,
        ownerIsCurrent: () => true,
      );
      check(
        editor.workflow.state.operation,
      ).equals(DirectEditorOperation.testing);

      final concurrentSave = await editor.workflow.save(
        messages: _messages,
        confirmCredentialTransfer: (_) async => true,
        ownerIsCurrent: () => true,
      );
      check(concurrentSave.outcome).equals(DirectEditorActionOutcome.cancelled);

      probe.complete(const DirectConnectionProbe(reachable: false));
      final testResult = await testFuture;
      check(testResult.outcome).equals(DirectEditorActionOutcome.unreachable);
      check(editor.workflow.state.operation).equals(DirectEditorOperation.idle);
      check(editor.workflow.state.attempt.isVisible).isTrue();

      editor.form.name.text = 'Updated provider';
      check(editor.workflow.state.operationError).isNull();
      check(editor.workflow.state.attempt.isVisible).isFalse();
    },
  );

  test('save workflow validates and delegates persistence', () async {
    final target = _FakeDirectConnectionEditorTarget();
    final editor = _EditorHarness(target: target);
    addTearDown(editor.dispose);
    editor.form.hydrate(null);
    editor.form.setAuthentication(DirectAuthenticationMode.none);

    final result = await editor.workflow.save(
      messages: _messages,
      confirmCredentialTransfer: (_) async => true,
      ownerIsCurrent: () => true,
    );

    check(result.outcome).equals(DirectEditorActionOutcome.succeeded);
    check(target.savedProfile).isNotNull();
    check(target.savedProfile!.name).equals('My provider');
  });

  test('owner identity is captured once and includes auth epoch identity', () {
    final editor = _EditorHarness(
      source: DirectConnectionEditorSource.openWebUi,
    );
    addTearDown(editor.dispose);
    final epoch = Object();

    editor.workflow.captureOwner(
      serverId: 'server',
      accountId: 'account',
      authEpoch: epoch,
    );
    editor.workflow.captureOwner(
      serverId: 'replacement',
      accountId: 'replacement',
      authEpoch: Object(),
    );

    check(
      editor.workflow.ownerMatches(
        serverId: 'server',
        accountId: 'account',
        authEpoch: epoch,
      ),
    ).isTrue();
    check(
      editor.workflow.ownerMatches(
        serverId: 'server',
        accountId: 'account',
        authEpoch: Object(),
      ),
    ).isFalse();
  });

  test(
    'workflow publishes form and workflow state through one notifier',
    () async {
      final editor = _EditorHarness(
        source: DirectConnectionEditorSource.openWebUi,
      );
      addTearDown(editor.dispose);
      final epoch = Object();
      var notifications = 0;
      editor.workflow.addListener(() => notifications++);

      editor.workflow.markHydrated();
      editor.workflow.captureOwner(
        serverId: 'server',
        accountId: 'account',
        authEpoch: epoch,
      );
      check(editor.workflow.state.hydrated).isTrue();
      check(editor.workflow.state.owner).isNotNull();
      check(notifications).equals(0);
      await Future<void>.delayed(Duration.zero);
      check(notifications).equals(1);
      editor.form.name.text = 'Updated provider';
      check(notifications).equals(2);
    },
  );

  test(
    'disposed local editor ignores a late compare-and-swap conflict',
    () async {
      final save = Completer<void>();
      final target = _FakeDirectConnectionEditorTarget(
        saveHandler: (_) => save.future,
      );
      final editor = _EditorHarness(target: target);
      editor.form.hydrate(null);
      editor.form.setAuthentication(DirectAuthenticationMode.none);

      final result = editor.workflow.save(
        messages: _messages,
        confirmCredentialTransfer: (_) async => true,
        ownerIsCurrent: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      editor.dispose();
      save.completeError(
        DirectConnectionProfileConflictException(currentProfiles: const []),
      );

      check(
        (await result).outcome,
      ).equals(DirectEditorActionOutcome.unavailable);
    },
  );
}

final class _EditorHarness {
  _EditorHarness({
    DirectConnectionEditorSource source = DirectConnectionEditorSource.local,
    bool isNew = true,
    _FakeDirectConnectionEditorTarget? target,
  }) {
    final mode =
        target?.mode ??
        (isNew
            ? DirectConnectionEditorMode.create(source: source)
            : DirectConnectionEditorMode.edit(
                profileId: 'existing-profile',
                source: source,
              ));
    this.target = target ?? _FakeDirectConnectionEditorTarget(mode: mode);
    workflow = DirectConnectionEditorWorkflow(target: this.target);
    form = workflow.form;
  }

  late final _FakeDirectConnectionEditorTarget target;
  late final DirectConnectionEditorForm form;
  late final DirectConnectionEditorWorkflow workflow;

  void dispose() {
    workflow.dispose();
  }
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

final class _FakeDirectConnectionEditorTarget
    implements DirectConnectionEditorTarget {
  _FakeDirectConnectionEditorTarget({
    this.mode = const DirectConnectionEditorMode.create(),
    this.probeHandler,
    this.saveHandler,
  });

  @override
  final DirectConnectionEditorMode mode;
  final Future<DirectConnectionProbe> Function(DirectConnectionProfile)?
  probeHandler;
  final Future<void> Function(DirectEditorSaveRequest)? saveHandler;
  DirectConnectionProfile? savedProfile;

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) =>
      probeHandler?.call(profile) ??
      Future.value(const DirectConnectionProbe(reachable: true));

  @override
  Future<void> save(DirectEditorSaveRequest request) async {
    savedProfile = request.draft;
    await saveHandler?.call(request);
  }

  @override
  Future<bool> clearDirectPreferenceIfLastUsable(String profileId) async =>
      false;

  @override
  Future<void> restoreDirectPreference() async {}

  @override
  Future<void> delete(DirectEditorDeleteRequest request) async {}

  @override
  bool isConflict(Object error) =>
      error is DirectConnectionProfileConflictException;

  @override
  bool deletionMayHaveCommitted(Object error) => false;
}
