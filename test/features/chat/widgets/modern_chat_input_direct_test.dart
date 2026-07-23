import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/widgets/composer_overflow_menu.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('direct overflow does not load OpenWebUI user settings', (
    tester,
  ) async {
    final registry = DirectModelRegistry();
    final directModel = registry.replaceProfileModels(
      DirectConnectionProfile(
        id: 'local-settings',
        name: 'Local Ollama',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      ),
      [DirectRemoteModel(id: 'llava', isMultimodal: true)],
    ).single;
    final api = _CountingUserSettingsApi();
    addTearDown(api.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directModelRegistryProvider.overrideWithValue(registry),
          directModelDiscoveryProvider.overrideWith(
            _FixedDiscoveryController.new,
          ),
          selectedModelProvider.overrideWithValue(directModel),
          apiServiceProvider.overrideWithValue(api),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: ComposerOverflowSheet(onImageAttachment: _noop),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.userSettingsCalls, 0);
  });

  testWidgets(
    'server-owned direct-like model keeps OpenWebUI attachment actions',
    (tester) async {
      const serverModel = Model(
        id: 'direct:server:bW9kZWw',
        name: 'Server-owned direct-like model',
        metadata: {'backend': 'direct'},
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            directModelRegistryProvider.overrideWithValue(
              DirectModelRegistry(),
            ),
            directModelDiscoveryProvider.overrideWith(
              _FixedDiscoveryController.new,
            ),
            selectedModelProvider.overrideWithValue(serverModel),
            apiServiceProvider.overrideWithValue(null),
            webSearchAvailableProvider.overrideWithValue(false),
            imageGenerationAvailableProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ModernChatInput(
                onSendMessage: (_) {},
                onFileAttachment: () {},
                onServerFileAttachment: () {},
                onImageAttachment: () {},
                onCameraCapture: () {},
                onWebAttachment: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        directModelAcceptsImageInput(serverModel, DirectModelRegistry()),
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(find.byType(TextField))
            .contentInsertionConfiguration,
        isNotNull,
      );

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      final sheet = tester.widget<ComposerOverflowSheet>(
        find.byType(ComposerOverflowSheet),
      );
      expect(sheet.onFileAttachment, isNotNull);
      expect(sheet.onServerFileAttachment, isNotNull);
      expect(sheet.onWebAttachment, isNotNull);
      expect(sheet.onImageAttachment, isNotNull);
      expect(sheet.onCameraCapture, isNotNull);
    },
  );

  testWidgets(
    'fallback overflow sheet receives image callbacks for vision direct models',
    (tester) async {
      final registry = DirectModelRegistry();
      final directModel = registry.replaceProfileModels(
        DirectConnectionProfile(
          id: 'local',
          name: 'Local Ollama',
          adapterKey: kOllamaAdapterKey,
          baseUrl: 'http://localhost:11434',
        ),
        [DirectRemoteModel(id: 'llava', isMultimodal: true)],
      ).single;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            directModelRegistryProvider.overrideWithValue(registry),
            directModelDiscoveryProvider.overrideWith(
              _FixedDiscoveryController.new,
            ),
            selectedModelProvider.overrideWithValue(directModel),
            apiServiceProvider.overrideWithValue(null),
            webSearchAvailableProvider.overrideWithValue(false),
            imageGenerationAvailableProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ModernChatInput(
                onSendMessage: (_) {},
                onFileAttachment: () {},
                onServerFileAttachment: () {},
                onImageAttachment: () {},
                onCameraCapture: () {},
                onWebAttachment: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.contentInsertionConfiguration, isNotNull);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      final sheet = tester.widget<ComposerOverflowSheet>(
        find.byType(ComposerOverflowSheet),
      );
      expect(sheet.onFileAttachment, isNotNull);
      expect(sheet.onServerFileAttachment, isNull);
      expect(sheet.onWebAttachment, isNull);
      expect(sheet.onImageAttachment, isNotNull);
      expect(sheet.onCameraCapture, isNotNull);
    },
  );

  testWidgets(
    'text-only direct models keep file attachment overflow available',
    (tester) async {
      final registry = DirectModelRegistry();
      final directModel = registry.replaceProfileModels(
        DirectConnectionProfile(
          id: 'local-text',
          name: 'Local Ollama',
          adapterKey: kOllamaAdapterKey,
          baseUrl: 'http://localhost:11434',
        ),
        [DirectRemoteModel(id: 'llama3', isMultimodal: false)],
      ).single;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            directModelRegistryProvider.overrideWithValue(registry),
            directModelDiscoveryProvider.overrideWith(
              _FixedDiscoveryController.new,
            ),
            selectedModelProvider.overrideWithValue(directModel),
            apiServiceProvider.overrideWithValue(null),
            webSearchAvailableProvider.overrideWithValue(false),
            imageGenerationAvailableProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ModernChatInput(
                onSendMessage: (_) {},
                onFileAttachment: () {},
                onServerFileAttachment: () {},
                onImageAttachment: () {},
                onCameraCapture: () {},
                onWebAttachment: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(directModelAcceptsImageInput(directModel, registry), isFalse);
      expect(
        shouldShowComposerOverflowButton(
          isHermesComposer: false,
          isDirectComposer: true,
          directSupportsImages: false,
          directHasLocalAttachmentActions: true,
        ),
        isTrue,
      );
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.contentInsertionConfiguration, isNull);
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.byType(ComposerOverflowSheet), findsNothing);
    },
  );

  testWidgets(
    'vision direct model with no image callbacks hides empty overflow',
    (tester) async {
      final registry = DirectModelRegistry();
      final directModel = registry.replaceProfileModels(
        DirectConnectionProfile(
          id: 'local-no-callbacks',
          name: 'Local Ollama',
          adapterKey: kOllamaAdapterKey,
          baseUrl: 'http://localhost:11434',
        ),
        [DirectRemoteModel(id: 'llava', isMultimodal: true)],
      ).single;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            directModelRegistryProvider.overrideWithValue(registry),
            directModelDiscoveryProvider.overrideWith(
              _FixedDiscoveryController.new,
            ),
            selectedModelProvider.overrideWithValue(directModel),
            apiServiceProvider.overrideWithValue(null),
            webSearchAvailableProvider.overrideWithValue(false),
            imageGenerationAvailableProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: ModernChatInput(onSendMessage: (_) {})),
          ),
        ),
      );
      await tester.pump();

      expect(directModelAcceptsImageInput(directModel, registry), isTrue);
      expect(find.byIcon(Icons.add), findsNothing);
      expect(find.byType(ComposerOverflowSheet), findsNothing);
    },
  );

  testWidgets('covered composer removes its light-only surface shadow', (
    tester,
  ) async {
    Finder composerSurfaceShadow() => find.descendant(
      of: find.byType(ModernChatInput),
      matching: find.byWidgetPredicate((widget) {
        if (widget case DecoratedBox(
          decoration: final BoxDecoration decoration,
        )) {
          return decoration.boxShadow?.any(
                (shadow) => shadow.color == const Color(0x18000000),
              ) ??
              false;
        }
        return false;
      }),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiServiceProvider.overrideWithValue(null)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (nestedContext) => Scaffold(
                body: Column(
                  children: [
                    Expanded(child: ModernChatInput(onSendMessage: (_) {})),
                    TextButton(
                      onPressed: () => ThemedSheets.showRoundedPage<void>(
                        context: nestedContext,
                        builder: (_) => const SizedBox.expand(),
                      ),
                      child: const Text('Open sheet'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(composerSurfaceShadow(), findsOneWidget);

    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(composerSurfaceShadow(), findsNothing);

    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await tester.pumpAndSettle();
    expect(ThemedSheets.hasActiveSheet, isFalse);
  });
}

final class _FixedDiscoveryController extends DirectModelDiscoveryController {
  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState();
}

void _noop() {}

final class _CountingUserSettingsApi extends ApiService {
  _CountingUserSettingsApi._(this._workerManager)
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.test',
        ),
        workerManager: _workerManager,
      );

  factory _CountingUserSettingsApi() =>
      _CountingUserSettingsApi._(WorkerManager());

  final WorkerManager _workerManager;
  int userSettingsCalls = 0;

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async {
    userSettingsCalls++;
    return const <String, dynamic>{};
  }

  @override
  void dispose() {
    super.dispose();
    _workerManager.dispose();
  }
}
