import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/model_list_tile.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'direct_connections_ui_test_support.dart';

void main() {
  group('direct connection form parsing', () {
    test('parses string custom headers', () {
      check(
        parseDirectCustomHeaders(
          '{"X-Organization":"team-a","X-Region":"local"}',
        ),
      ).deepEquals({'X-Organization': 'team-a', 'X-Region': 'local'});
    });

    test('rejects non-string custom header values', () {
      check(() => parseDirectCustomHeaders('{"X-Retry": 2}'))
          .throws<FormatException>();
    });

    test('normalizes surrounding custom header name whitespace', () {
      check(parseDirectCustomHeaders('{" X-Organization ":"team-a"}'))
          .deepEquals({'X-Organization': 'team-a'});
    });

    test('deduplicates manual model ids while preserving order', () {
      check(parseDirectManualModelIds('model-a\n model-b,model-a\n'))
          .deepEquals(['model-a', 'model-b']);
    });

    test('deduplicates model tags while preserving order', () {
      check(parseDirectModelTags('local, private\nlocal'))
          .deepEquals(['local', 'private']);
    });

    test('normalizes whitespace and trailing slash', () {
      check(normalizeDirectBaseUrl(' https://provider.example/v1/ '))
          .equals('https://provider.example/v1');
      check(normalizeDirectBaseUrl('http://localhost:11434/'))
          .equals('http://localhost:11434/');
    });

    test('route target canonicalizes create/edit and source state', () {
      final create = DirectConnectionEditorMode.fromRoute(
        profileId: 'new',
        source: DirectConnectionEditorSource.openWebUi,
      );
      final edit = DirectConnectionEditorMode.fromRoute(
        profileId: 'profile-1',
        source: DirectConnectionEditorSource.local,
      );

      check(create.isNew).isTrue();
      check(create.profileId).isNull();
      check(create.isOpenWebUi).isTrue();
      check(edit.isNew).isFalse();
      check(edit.profileId).equals('profile-1');
      check(edit.isOpenWebUi).isFalse();
    });

    test('preserves only an untouched existing keyless server bearer', () {
      check(
        requiresDirectApiKey(
          authentication: DirectAuthenticationMode.bearer,
          mode: const DirectConnectionEditorMode.edit(
            profileId: 'existing',
            source: DirectConnectionEditorSource.openWebUi,
          ),
          savedAuthentication: DirectAuthenticationMode.bearer,
          apiKeyDirty: false,
          originChanged: false,
        ),
      ).isFalse();
      check(
        requiresDirectApiKey(
          authentication: DirectAuthenticationMode.bearer,
          mode: const DirectConnectionEditorMode.edit(
            profileId: 'existing',
            source: DirectConnectionEditorSource.openWebUi,
          ),
          savedAuthentication: DirectAuthenticationMode.none,
          apiKeyDirty: true,
          originChanged: false,
        ),
      ).isTrue();
      check(
        requiresDirectApiKey(
          authentication: DirectAuthenticationMode.bearer,
          mode: const DirectConnectionEditorMode.edit(
            profileId: 'existing',
            source: DirectConnectionEditorSource.openWebUi,
          ),
          savedAuthentication: DirectAuthenticationMode.bearer,
          apiKeyDirty: false,
          originChanged: true,
        ),
      ).isTrue();
    });

    test('an edited origin cannot inherit TLS material for a probe', () {
      final previous = DirectConnectionProfile(
        id: 'secure-profile',
        name: 'Secure provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://old.example/v1',
        apiKey: 'old-key',
        allowSelfSignedCertificates: true,
        mtlsCertificateChainPem: 'CERT',
        mtlsPrivateKeyPem: 'KEY',
        mtlsPrivateKeyPassword: 'password',
      );
      final draft = previous.copyWith(
        baseUrl: 'https://new.example/v1',
        apiKey: 'new-key',
      );

      final safe = secureDirectDraftForEditedOrigin(
        previous: previous,
        draft: draft,
        secretsConfirmedForNewOrigin: true,
      );

      check(safe.apiKey).equals('new-key');
      check(safe.allowSelfSignedCertificates).isFalse();
      check(safe.mtlsCertificateChainPem).isNull();
      check(safe.mtlsPrivateKeyPem).isNull();
      check(safe.mtlsPrivateKeyPassword).isNull();
    });

    test(
      'origin edits require explicit confirmation for the whole header map',
      () {
        final previous = DirectConnectionProfile(
          id: 'secure-profile',
          name: 'Secure provider',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://old.example/v1',
          customHeaders: const {'X-Api-Key': 'old-key', 'X-Tenant': 'tenant-a'},
        );
        final whitespaceOnly = previous.copyWith(
          baseUrl: 'https://new.example/v1',
          customHeaders: parseDirectCustomHeaders(
            '{  "X-Api-Key" : "old-key", "X-Tenant": "tenant-a" }',
          ),
        );
        final oneHeaderEdited = whitespaceOnly.copyWith(
          customHeaders: const {'X-Api-Key': 'new-key', 'X-Tenant': 'tenant-a'},
        );

        check(
          requiresDirectOriginCredentialConfirmation(
            previous: previous,
            draft: whitespaceOnly,
          ),
        ).isTrue();
        check(
          requiresDirectOriginCredentialConfirmation(
            previous: previous,
            draft: oneHeaderEdited,
          ),
        ).isTrue();
        check(
          requiresDirectOriginCredentialConfirmation(
            previous: previous,
            draft: oneHeaderEdited.copyWith(customHeaders: const {}),
          ),
        ).isFalse();
      },
    );
  });

  test('direct model badge uses its configured profile name', () {
    const model = Model(
      id: 'direct:home:encoded',
      name: 'Local model',
      metadata: {'backend': 'direct', 'profileName': 'Home Ollama'},
    );
    check(directModelSourceLabel(model)).equals('Home Ollama');
    check(directModelSourceLabel(const Model(id: 'server', name: 'Server')))
        .isNull();
  });

  testWidgets('direct source and model tags deduplicate case-insensitively', (
    tester,
  ) async {
    const model = Model(
      id: 'direct:work:model',
      name: 'Local model',
      metadata: {
        'backend': 'direct',
        'profileName': 'Work',
        'tags': ['work'],
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ModelListTile(
            model: model,
            isSelected: false,
            onTap: directTestNoop,
          ),
        ),
      ),
    );

    expect(find.byType(ModelTagChip), findsOneWidget);
    expect(find.text('WORK'), findsOneWidget);
  });

  testWidgets('loaded model badge is visible without changing selection', (
    tester,
  ) async {
    const model = Model(id: 'direct:home:model', name: 'Local model');

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ModelListTile(
            model: model,
            isSelected: false,
            isLoaded: true,
            onTap: directTestNoop,
          ),
        ),
      ),
    );

    check(find.byType(ModelLoadedChip).evaluate()).length.equals(1);
    check(find.text('Loaded').evaluate()).length.equals(1);
    check(find.byIcon(Icons.check).evaluate()).isEmpty();
  });

  testWidgets('model selector uses a readable primary label size', (
    tester,
  ) async {
    const model = Model(id: 'direct:home:model', name: 'Local model');

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ModelListTile(
            model: model,
            isSelected: false,
            onTap: directTestNoop,
          ),
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('Local model'));
    check(label.style?.fontSize).equals(16);
    check(label.style?.height).equals(1.35);
  });
}
