import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/model_list_tile.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

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
      check(
        () => parseDirectCustomHeaders('{"X-Retry": 2}'),
      ).throws<FormatException>();
    });

    test('deduplicates manual model ids while preserving order', () {
      check(
        parseDirectManualModelIds('model-a\n model-b,model-a\n'),
      ).deepEquals(['model-a', 'model-b']);
    });

    test('normalizes whitespace and trailing slash', () {
      check(
        normalizeDirectBaseUrl(' https://provider.example/v1/ '),
      ).equals('https://provider.example/v1');
      check(
        normalizeDirectBaseUrl('http://localhost:11434/'),
      ).equals('http://localhost:11434/');
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
    check(
      directModelSourceLabel(const Model(id: 'server', name: 'Server')),
    ).isNull();
  });

  testWidgets('management content shows profiles and history policy', (
    tester,
  ) async {
    var syncEnabled = true;
    final profiles = [
      DirectConnectionProfile(
        id: 'home',
        name: 'Home Ollama',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://192.168.1.5:11434',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: profiles,
            syncWithOpenWebUi: syncEnabled,
            isOnboarding: false,
            onSyncChanged: (value) => syncEnabled = value,
            onAdd: () {},
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Direct Connections'), findsOneWidget);
    expect(find.text('Open WebUI history'), findsOneWidget);
    expect(find.text('Home Ollama'), findsOneWidget);
    expect(find.textContaining('http://192.168.1.5:11434'), findsOneWidget);
    expect(find.text('Add connection'), findsOneWidget);

    await tester.tap(find.byType(AdaptiveSwitch));
    await tester.pump();
    check(syncEnabled).isFalse();
  });

  testWidgets('delete confirmation serializes editor operations', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'home',
      name: 'Home provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'secret',
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(profileId: 'home'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Delete connection?'), findsOneWidget);
    final save = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Save',
      ),
    );
    final testConnection = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Test connection',
      ),
    );
    final delete = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ConduitButton && widget.text == 'Delete connection',
      ),
    );
    expect(save.onPressed, isNull);
    expect(testConnection.onPressed, isNull);
    expect(delete.isLoading, isTrue);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final restoredDelete = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ConduitButton && widget.text == 'Delete connection',
      ),
    );
    expect(restoredDelete.isLoading, isFalse);
    expect(restoredDelete.onPressed, isNotNull);
  });
}
