import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/model_list_tile.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

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

    test('normalizes surrounding custom header name whitespace', () {
      check(
        parseDirectCustomHeaders('{" X-Organization ":"team-a"}'),
      ).deepEquals({'X-Organization': 'team-a'});
    });

    test('deduplicates manual model ids while preserving order', () {
      check(
        parseDirectManualModelIds('model-a\n model-b,model-a\n'),
      ).deepEquals(['model-a', 'model-b']);
    });

    test('deduplicates model tags while preserving order', () {
      check(
        parseDirectModelTags('local, private\nlocal'),
      ).deepEquals(['local', 'private']);
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ModelListTile(model: model, isSelected: false, onTap: _noop),
        ),
      ),
    );

    expect(find.byType(ModelTagChip), findsOneWidget);
    expect(find.text('WORK'), findsOneWidget);
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

  testWidgets('editor restores the OpenAI-family completion API mode', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'lm-studio',
      name: 'LM Studio',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'http://localhost:1234/v1',
      openAiApiMode: DirectOpenAiApiMode.responses,
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
          home: const DirectConnectionEditorPage(profileId: 'lm-studio'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -420));
    await tester.pumpAndSettle();

    final selector = tester
        .widget<AdaptiveSegmentedSelector<DirectOpenAiApiMode>>(
          find.byKey(const ValueKey<String>('direct-openai-api-mode-selector')),
        );
    expect(selector.value, DirectOpenAiApiMode.responses);
    expect(find.text('Chat Completions'), findsOneWidget);
    expect(find.text('Responses'), findsOneWidget);
  });

  testWidgets('editor rejects a save from a stale profile snapshot', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'shared-profile',
      name: 'Original provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'original-secret',
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
          home: const DirectConnectionEditorPage(profileId: 'shared-profile'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );

    await container
        .read(directConnectionProfilesProvider.notifier)
        .upsert(
          profile.copyWith(
            name: 'Concurrent provider',
            apiKey: 'concurrent-secret',
          ),
        );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('direct-connection-name-field')),
      'Stale rename',
    );
    await tester.scrollUntilVisible(
      find.text('Save'),
      500,
      scrollable: find.byType(Scrollable).first,
    );

    final save = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Save',
        skipOffstage: false,
      ),
    );
    save.onPressed!();
    await tester.pumpAndSettle();

    expect(
      find.text('This connection changed elsewhere. Reopen it before saving.'),
      findsAtLeastNWidgets(1),
    );
    final saved = container
        .read(directConnectionProfilesProvider)
        .requireValue
        .single;
    expect(saved.name, 'Concurrent provider');
    expect(saved.apiKey, 'concurrent-secret');
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

  testWidgets('delete checks profiles added while confirmation is open', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'home',
      name: 'Home provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'secret',
    );
    final alternate = DirectConnectionProfile(
      id: 'backup',
      name: 'Backup provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://backup.example/v1',
      apiKey: 'backup-secret',
    );
    final backendController = _TrackingPreferredBackendController();
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });
    final router = GoRouter(
      initialLocation: '/edit',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const SizedBox.shrink(),
          routes: [
            GoRoute(
              path: 'edit',
              builder: (_, _) =>
                  const DirectConnectionEditorPage(profileId: 'home'),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
          preferredBackendProvider.overrideWith(() => backendController),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );

    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await container
        .read(directConnectionProfilesProvider.notifier)
        .upsert(alternate);
    await tester.pump();
    expect(
      container.read(directConnectionProfilesProvider).requireValue,
      hasLength(2),
    );

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      container
          .read(directConnectionProfilesProvider)
          .requireValue
          .map((item) => item.id),
      ['backup'],
    );
    expect(container.read(preferredBackendProvider), PreferredBackend.direct);
    expect(backendController.writes, isEmpty);
  });

  testWidgets('backend preference failure preserves the last direct profile', (
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
          preferredBackendProvider.overrideWith(
            _FailingPreferredBackendController.new,
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(profileId: 'home'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );

    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Could not delete this connection.'), findsOneWidget);
    expect(
      container.read(directConnectionProfilesProvider).requireValue.single.id,
      'home',
    );
    expect(container.read(preferredBackendProvider), PreferredBackend.direct);
    final durable = await const FlutterSecureStorage().read(
      key: 'direct_connection_profiles_v1',
    );
    expect(durable, contains('secret'));
  });

  testWidgets(
    'profile write failure restores a pre-cleared direct preference',
    (tester) async {
      final profile = DirectConnectionProfile(
        id: 'home',
        name: 'Home provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://provider.example/v1',
        apiKey: 'secret',
      );
      final backendController = _TrackingPreferredBackendController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStorageProvider.overrideWithValue(
              _RejectingProfileWriteSecureStorage(
                DirectConnectionProfilesDocument([profile]).encode(),
              ),
            ),
            preferredBackendProvider.overrideWith(() => backendController),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const DirectConnectionEditorPage(profileId: 'home'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DirectConnectionEditorPage)),
      );

      await tester.scrollUntilVisible(
        find.text('Delete connection'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Delete connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Could not delete this connection.'), findsOneWidget);
      expect(
        container.read(directConnectionProfilesProvider).requireValue.single.id,
        'home',
      );
      expect(container.read(preferredBackendProvider), PreferredBackend.direct);
      expect(backendController.writes, [
        PreferredBackend.unset,
        PreferredBackend.direct,
      ]);
    },
  );
}

void _noop() {}

final class _FailingPreferredBackendController
    extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.direct;

  @override
  Future<void> set(PreferredBackend backend) async {
    throw StateError('preference write failed');
  }
}

final class _TrackingPreferredBackendController
    extends PreferredBackendController {
  final List<PreferredBackend> writes = [];

  @override
  PreferredBackend build() => PreferredBackend.direct;

  @override
  Future<void> set(PreferredBackend backend) async {
    writes.add(backend);
    state = backend;
  }
}

final class _RejectingProfileWriteSecureStorage
    implements FlutterSecureStorage {
  _RejectingProfileWriteSecureStorage(this.raw);

  final String raw;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => raw;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('profile write failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
