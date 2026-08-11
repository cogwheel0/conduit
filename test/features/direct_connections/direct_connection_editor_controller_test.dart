import 'package:checks/checks.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_controller.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('draft controller owns provider transitions and profile creation', () {
    final controller = DirectConnectionEditorController(
      isOpenWebUi: false,
      isNew: true,
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
    controller.markBaseUrlChanged();

    controller.headerName.text = 'X-Pending';
    controller.markHeaderInputChanged();

    check(controller.originBoundSecretsReviewed).isFalse();
  });
}
