import 'dart:io';

import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:conduit/features/chat/widgets/composer_overflow_menu.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:checks/checks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native composer glass uses non-animated cursor opacity', () {
    check(
      composerCursorOpacityAnimates(usesNativePlatformView: true),
    ).equals(false);
    check(
      composerCursorOpacityAnimates(usesNativePlatformView: false),
    ).equals(true);
  });

  test('native composer hides the blinking caret under its selection menu', () {
    check(
      composerShowsCursor(
        usesNativePlatformView: true,
        selectionMenuVisible: true,
      ),
    ).isFalse();
    check(
      composerShowsCursor(
        usesNativePlatformView: true,
        selectionMenuVisible: false,
      ),
    ).isTrue();
    check(
      composerShowsCursor(
        usesNativePlatformView: false,
        selectionMenuVisible: true,
      ),
    ).isTrue();
  });

  testWidgets('composer selection menu reports mount and removal', (
    tester,
  ) async {
    final visibility = <bool>[];

    await tester.pumpWidget(
      MaterialApp(
        home: buildComposerSelectionMenuLifecycle(
          onVisibilityChanged: visibility.add,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();

    check(visibility).deepEquals(<bool>[true]);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    check(visibility).deepEquals(<bool>[true, false]);
  });

  test('composer measurement style matches recording typography', () {
    final recordingStyle = ModernChatInput.debugComposerInputTextStyle(
      isRecording: true,
    );
    final idleStyle = ModernChatInput.debugComposerInputTextStyle(
      isRecording: false,
    );

    check(recordingStyle.fontWeight).equals(FontWeight.w500);
    check(recordingStyle.fontStyle).equals(FontStyle.italic);
    check(idleStyle.fontWeight).equals(FontWeight.w400);
    check(idleStyle.fontStyle).equals(FontStyle.normal);
  });

  test('only Android enlarges the compact overflow add glyph', () {
    check(
      ModernChatInput.debugOverflowIconSize(
        isAndroid: true,
        attachmentPanelVisible: false,
      ),
    ).equals(28);
    check(
      ModernChatInput.debugOverflowIconSize(
        isAndroid: false,
        attachmentPanelVisible: false,
      ),
    ).equals(IconSize.large);
    check(
      ModernChatInput.debugOverflowIconSize(
        isAndroid: true,
        attachmentPanelVisible: true,
      ),
    ).equals(IconSize.large);
  });

  test('OpenWebUI explicit attachment capability denials fail closed', () {
    final model = Model.fromJson({
      'id': 'text-only',
      'name': 'Text only',
      'info': {
        'meta': {
          'capabilities': {'vision': false, 'file_upload': false},
        },
      },
    });
    final container = ProviderContainer(
      overrides: [selectedModelProvider.overrideWithValue(model)],
    );
    addTearDown(container.dispose);

    expect(container.read(visionCapableModelsProvider), isEmpty);
    expect(container.read(fileUploadCapableModelsProvider), isEmpty);
  });

  test('direct file picking exposes local documents and supported images', () {
    final registry = DirectModelRegistry();
    final directModel = registry.replaceProfileModels(
      DirectConnectionProfile(
        id: 'cloud',
        name: 'Ollama Cloud',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'https://ollama.com',
      ),
      [DirectRemoteModel(id: 'gemma3', isMultimodal: true)],
    ).single;

    final extensions = localFilePickerExtensionsForModel(directModel)!;
    expect(extensions, contains('png'));
    expect(extensions, contains('heic'));
    expect(extensions, contains('txt'));
    expect(extensions, contains('docx'));
    expect(extensions, isNot(contains('pdf')));
  });

  test('text-only direct file picking exposes documents but not images', () {
    final registry = DirectModelRegistry();
    final directModel = registry.replaceProfileModels(
      DirectConnectionProfile(
        id: 'local',
        name: 'Local Ollama',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      ),
      [DirectRemoteModel(id: 'llama3', isMultimodal: false)],
    ).single;

    final extensions = localFilePickerExtensionsForModel(directModel)!;
    expect(extensions, contains('txt'));
    expect(extensions, contains('docx'));
    expect(extensions, isNot(contains('png')));
    expect(extensions, isNot(contains('heic')));
    expect(extensions, isNot(contains('pdf')));
  });

  test('OpenRouter direct file picking exposes bounded PDF inputs', () {
    final registry = DirectModelRegistry();
    final directModel = registry.replaceProfileModels(
      DirectConnectionProfile(
        id: 'openrouter',
        name: 'OpenRouter',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: kOpenRouterApiBaseUrl,
      ),
      [DirectRemoteModel(id: 'anthropic/claude-sonnet-4')],
    ).single;

    final extensions = localFilePickerExtensionsForModel(directModel)!;

    expect(extensions, contains('pdf'));
    expect(directModel.capabilities?['web_search'], isTrue);
    expect(
      directModel.capabilities?['image_generation'],
      isTrue,
      reason: 'The OpenRouter Image API works with text-only parent models.',
    );
  });

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

  testWidgets('text-only direct models expose files but hide image actions', (
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
        directHasOverflowActions: true,
      ),
      isTrue,
    );
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.contentInsertionConfiguration, isNull);
    expect(find.byIcon(Icons.add), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    final sheet = tester.widget<ComposerAttachmentKeyboard>(
      find.byType(ComposerAttachmentKeyboard),
    );
    expect(sheet.onFileAttachment, isNotNull);
    expect(sheet.onServerFileAttachment, isNull);
    expect(sheet.onImageAttachment, isNull);
    expect(sheet.onCameraCapture, isNull);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Photo'), findsNothing);
    expect(find.text('Camera'), findsNothing);
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
      expect(find.text('Photo'), findsNothing);
      expect(find.text('Camera'), findsNothing);
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

  testWidgets('focus stays compact until the composer becomes multiline', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiServiceProvider.overrideWithValue(null)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ModernChatInput(onSendMessage: (_) {})),
        ),
      ),
    );
    await tester.pump();

    const compactShellKey = ValueKey('compact-composer-shell');
    const expandedShellKey = ValueKey('expanded-composer-shell');
    const expandedInputKey = ValueKey('composer-expanded-input');
    const expandedButtonsKey = ValueKey('composer-expanded-buttons');
    const quickPillsKey = ValueKey('composer-quick-pills');

    expect(find.byKey(compactShellKey), findsOneWidget);
    expect(find.byKey(expandedShellKey), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump();

    final composerField = tester.widget<TextField>(find.byType(TextField));
    expect(composerField.focusNode?.hasFocus, isTrue);
    expect(find.byKey(compactShellKey), findsOneWidget);
    expect(find.byKey(expandedShellKey), findsNothing);

    await tester.enterText(find.byType(TextField), 'first line\nsecond line');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(compactShellKey), findsNothing);
    expect(find.byKey(expandedShellKey), findsOneWidget);
    expect(find.byKey(expandedInputKey), findsOneWidget);
    expect(find.byKey(expandedButtonsKey), findsOneWidget);
    expect(find.byKey(quickPillsKey), findsNothing);

    final inputInsets = tester
        .widget<Padding>(find.byKey(expandedInputKey))
        .padding
        .resolve(TextDirection.ltr);
    final actionInsets = tester
        .widget<Padding>(find.byKey(expandedButtonsKey))
        .padding
        .resolve(TextDirection.ltr);
    expect(inputInsets.left, 8);
    expect(inputInsets.right, 8);
    expect(actionInsets.left, 8);
    expect(actionInsets.right, 8);

    await tester.enterText(find.byType(TextField), 'single line');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(compactShellKey), findsOneWidget);
    expect(find.byKey(expandedShellKey), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );
  });

  testWidgets('a visually wrapped second line expands the composer', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiServiceProvider.overrideWithValue(null)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ModernChatInput(onSendMessage: (_) {})),
        ),
      ),
    );
    await tester.pump();

    const wrappedText = 'A focused message wraps onto line two';
    expect(wrappedText.length, lessThan(51));

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    final editableContext = tester.element(find.byType(EditableText));
    final textPainter = TextPainter(
      text: TextSpan(text: wrappedText, style: editable.style),
      textDirection: Directionality.of(editableContext),
      textScaler: MediaQuery.textScalerOf(editableContext),
      maxLines: 2,
    );
    try {
      textPainter.layout(
        maxWidth: tester.getSize(find.byType(EditableText)).width,
      );
      expect(textPainter.computeLineMetrics().length, 2);
    } finally {
      textPainter.dispose();
    }

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), wrappedText);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('compact-composer-shell')), findsNothing);
    expect(
      find.byKey(const ValueKey('expanded-composer-shell')),
      findsOneWidget,
    );
  });

  testWidgets('unchanged draft reflows when the composer width changes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiServiceProvider.overrideWithValue(null)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ModernChatInput(onSendMessage: (_) {})),
        ),
      ),
    );
    await tester.pump();

    const compactShellKey = ValueKey('compact-composer-shell');
    const expandedShellKey = ValueKey('expanded-composer-shell');
    const wrappedText = 'A focused message wraps onto line two';

    await tester.enterText(find.byType(TextField), wrappedText);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(compactShellKey), findsOneWidget);
    expect(find.byKey(expandedShellKey), findsNothing);

    tester.view.physicalSize = const Size(320, 800);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(compactShellKey), findsNothing);
    expect(find.byKey(expandedShellKey), findsOneWidget);

    tester.view.physicalSize = const Size(1000, 800);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(compactShellKey), findsOneWidget);
    expect(find.byKey(expandedShellKey), findsNothing);
  });

  testWidgets('compact composer uses symmetric horizontal insets', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiServiceProvider.overrideWithValue(null)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ModernChatInput(
              onSendMessage: (_) {},
              onFileAttachment: _noop,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final compactInsets = tester
        .widget<Container>(
          find.byKey(const ValueKey('compact-composer-content')),
        )
        .padding!
        .resolve(TextDirection.ltr);

    expect(compactInsets.left, 8);
    expect(compactInsets.right, 8);

    final compactShell = find.byKey(const ValueKey('compact-composer-shell'));
    final overflowButton = find.byKey(
      const ValueKey('composer-overflow-button'),
    );
    expect(
      find.descendant(of: compactShell, matching: overflowButton),
      findsOneWidget,
    );

    final shellRect = tester.getRect(compactShell);
    final viewWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(shellRect.left, 16);
    expect(viewWidth - shellRect.right, 16);

    final overflowCenter = tester.getCenter(find.byIcon(Icons.add));
    final primaryCenter = tester.getCenter(
      find.byKey(const ValueKey('primary-btn-send-muted')),
    );
    expect(
      overflowCenter.dx - shellRect.left,
      closeTo(shellRect.right - primaryCenter.dx, 0.01),
    );

    await tester.enterText(find.byType(TextField), 'Hi');
    await tester.pump();

    final fieldRect = tester.getRect(find.byType(TextField));
    final overflowRect = tester.getRect(overflowButton);
    final activePrimaryRect = tester.getRect(
      find.byKey(const ValueKey('primary-btn-send')),
    );
    expect(fieldRect.left - overflowRect.right, Spacing.xs);
    expect(activePrimaryRect.left - fieldRect.right, Spacing.xs);
  });

  testWidgets('secondary composer actions use plain icon buttons', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          notesFeatureEnabledProvider.overrideWith(
            _EnabledNotesFeatureNotifier.new,
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ModernChatInput(
              onSendMessage: (_) {},
              onFileAttachment: _noop,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    AdaptiveButton actionButton(Finder ancestor) => tester.widget(
      find.descendant(of: ancestor, matching: find.byType(AdaptiveButton)),
    );

    expect(
      actionButton(
        find.byKey(const ValueKey('composer-overflow-button')),
      ).style,
      AdaptiveButtonStyle.plain,
    );

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Draft\nnote');
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<AdaptiveButton>(
            find.byKey(const ValueKey('create-draft-note-button')),
          )
          .style,
      AdaptiveButtonStyle.plain,
    );
  });

  testWidgets('non-Android add icon matches the standard mic glyph', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          voiceInputAvailableProvider.overrideWith((_) async => true),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ModernChatInput(
              onSendMessage: (_) {},
              onFileAttachment: _noop,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final addIcon = tester.widget<Icon>(find.byIcon(Icons.add));
    final micIcon = tester.widget<Icon>(find.byIcon(Icons.mic));
    final expectedAddIconSize = Platform.isAndroid ? 28 : IconSize.large;
    expect(addIcon.size, expectedAddIconSize);
    expect(micIcon.size, IconSize.large);

    final addButton = find.byKey(
      const ValueKey<String>('composer-overflow-button'),
    );
    final micButton = find.byKey(
      const ValueKey<String>('composer-dictation-start'),
    );
    expect(tester.getSize(addButton), tester.getSize(micButton));
  });

  testWidgets('overflow close control keeps its compact size when expanded', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiServiceProvider.overrideWithValue(null)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ModernChatInput(
              onSendMessage: (_) {},
              onFileAttachment: _noop,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final overflowButton = find.byKey(
      const ValueKey<String>('composer-overflow-button'),
    );
    final addControlSize = tester.getSize(overflowButton);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    final compactCloseControlSize = tester.getSize(overflowButton);
    final compactCloseGlyphSize = tester
        .widget<Icon>(find.byIcon(Icons.close))
        .size;
    expect(compactCloseControlSize, addControlSize);

    await tester.enterText(find.byType(TextField), 'first line\nsecond line');
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('expanded-composer-shell')),
      findsOneWidget,
    );
    expect(tester.getSize(overflowButton), compactCloseControlSize);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.close)).size,
      compactCloseGlyphSize,
    );
  });

  testWidgets('explicit quick-pill selection keeps pill composer visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          appSettingsProvider.overrideWith(_QuickPillAppSettingsNotifier.new),
          webSearchAvailableProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ModernChatInput(onSendMessage: (_) {})),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('expanded-composer-shell')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('composer-quick-pills')), findsOneWidget);
    expect(find.text('Web'), findsOneWidget);
  });
}

final class _QuickPillAppSettingsNotifier extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(quickPills: ['web']);
}

final class _EnabledNotesFeatureNotifier extends NotesFeatureEnabledNotifier {
  @override
  bool build() => true;
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
