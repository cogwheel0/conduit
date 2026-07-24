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
  test('attachment panel matches the full IME footprint', () {
    expect(
      fallbackAttachmentPanelHeight(
        keyboardHeight: 300,
        bottomSafeInset: 24,
        retainedSafeAreaOverlap: 2,
        availableHeight: 800,
      ),
      278,
    );
    expect(
      fallbackAttachmentPanelHeight(
        keyboardHeight: 0,
        bottomSafeInset: 24,
        retainedSafeAreaOverlap: 2,
        availableHeight: 800,
      ),
      282,
    );
  });

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
            body: ComposerAttachmentKeyboard(onImageAttachment: _noop),
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

      final sheet = tester.widget<ComposerAttachmentKeyboard>(
        find.byType(ComposerAttachmentKeyboard),
      );
      expect(sheet.onFileAttachment, isNotNull);
      expect(sheet.onServerFileAttachment, isNotNull);
      expect(sheet.onWebAttachment, isNotNull);
      expect(sheet.onImageAttachment, isNotNull);
      expect(sheet.onCameraCapture, isNotNull);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.byKey(const ValueKey('composer-attachment-keyboard')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.close), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(ComposerAttachmentKeyboard), findsNothing);
      expect(find.byIcon(Icons.add), findsOneWidget);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.close), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byType(ComposerAttachmentKeyboard), findsNothing);
      expect(find.byIcon(Icons.add), findsOneWidget);
    },
  );

  testWidgets(
    'managed Android replacement keeps composer fixed while swapping panels',
    (tester) async {
      final keyboardInset = ValueNotifier<double>(300);
      addTearDown(keyboardInset.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            directModelRegistryProvider.overrideWithValue(
              DirectModelRegistry(),
            ),
            directModelDiscoveryProvider.overrideWith(
              _FixedDiscoveryController.new,
            ),
            selectedModelProvider.overrideWithValue(
              const Model(id: 'server-model', name: 'Server model'),
            ),
            apiServiceProvider.overrideWithValue(null),
            webSearchAvailableProvider.overrideWithValue(false),
            imageGenerationAvailableProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ValueListenableBuilder<double>(
              valueListenable: keyboardInset,
              builder: (context, inset, _) => MediaQuery(
                data: MediaQueryData(
                  size: const Size(400, 800),
                  viewInsets: EdgeInsets.only(bottom: inset),
                  viewPadding: const EdgeInsets.only(bottom: 24),
                ),
                child: Scaffold(
                  resizeToAvoidBottomInset: false,
                  body: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: ModernChatInput(
                          managesSystemKeyboardInset: true,
                          onSendMessage: (_) {},
                          onFileAttachment: () {},
                        ),
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

      await tester.tap(find.byType(TextField));
      await tester.pump();
      final originalTop = tester.getTopLeft(find.byType(TextField)).dy;

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(TextField)).dy, originalTop);

      keyboardInset.value = 0;
      await tester.pump();
      expect(tester.getTopLeft(find.byType(TextField)).dy, originalTop);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.byType(ComposerAttachmentKeyboard), findsOneWidget);
      expect(tester.getTopLeft(find.byType(TextField)).dy, originalTop);

      keyboardInset.value = 150;
      await tester.pump();
      expect(find.byType(ComposerAttachmentKeyboard), findsOneWidget);
      expect(tester.getTopLeft(find.byType(TextField)).dy, originalTop);

      keyboardInset.value = 300;
      await tester.pump();
      await tester.pump();
      expect(find.byType(ComposerAttachmentKeyboard), findsNothing);
      expect(tester.getTopLeft(find.byType(TextField)).dy, originalTop);
    },
  );

  testWidgets(
    'fallback attachment panel receives callbacks for vision direct models',
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

      final sheet = tester.widget<ComposerAttachmentKeyboard>(
        find.byType(ComposerAttachmentKeyboard),
      );
      expect(sheet.onFileAttachment, isNotNull);
      expect(sheet.onServerFileAttachment, isNull);
      expect(sheet.onWebAttachment, isNull);
      expect(sheet.onImageAttachment, isNotNull);
      expect(sheet.onCameraCapture, isNotNull);
      expect(find.text('File'), findsOneWidget);
      expect(find.text('Photo'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Files'), findsNothing);
      expect(find.text('Web Page'), findsNothing);
    },
  );

  testWidgets(
    'attachment keyboard remains usable at narrow width and large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const serverModel = Model(id: 'server-model', name: 'Server model');

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
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
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

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('composer-attachment-action-strip')),
        findsOneWidget,
      );
      expect(find.byType(BottomSheet), findsNothing);
    },
  );

  testWidgets('direct models keep local media attachment actions available', (
    tester,
  ) async {
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
    expect(find.byType(ComposerAttachmentKeyboard), findsNothing);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('File'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets(
    'attachment keyboard preserves composer focus and restores the IME path',
    (tester) async {
      final registry = DirectModelRegistry();
      final directModel = registry.replaceProfileModels(
        DirectConnectionProfile(
          id: 'focused-direct',
          name: 'Ollama Cloud',
          adapterKey: kOllamaAdapterKey,
          baseUrl: 'https://ollama.com',
        ),
        [
          DirectRemoteModel(
            id: 'gemma3',
            capabilities: const {'ollama_cloud': true, 'web_search': true},
          ),
        ],
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
            webSearchAvailableProvider.overrideWithValue(true),
            imageGenerationAvailableProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ModernChatInput(
                onSendMessage: (_) {},
                onFileAttachment: () {},
                onImageAttachment: () {},
                onCameraCapture: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
        isTrue,
      );

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.byType(ComposerAttachmentKeyboard), findsOneWidget);
      expect(find.text('File'), findsOneWidget);
      expect(find.text('Photo'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Web Search'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
        isTrue,
      );

      await tester.tap(find.text('Web Search'));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byType(ComposerAttachmentKeyboard), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
        isTrue,
      );
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
      expect(find.byType(ComposerAttachmentKeyboard), findsNothing);
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
