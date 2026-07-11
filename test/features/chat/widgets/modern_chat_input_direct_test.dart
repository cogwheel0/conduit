import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/widgets/composer_overflow_menu.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      final sheet = tester.widget<ComposerOverflowSheet>(
        find.byType(ComposerOverflowSheet),
      );
      expect(sheet.onFileAttachment, isNull);
      expect(sheet.onServerFileAttachment, isNull);
      expect(sheet.onWebAttachment, isNull);
      expect(sheet.onImageAttachment, isNotNull);
      expect(sheet.onCameraCapture, isNotNull);
    },
  );

  testWidgets(
    'fallback overflow sheet hides image actions for text-only direct models',
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

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      final sheet = tester.widget<ComposerOverflowSheet>(
        find.byType(ComposerOverflowSheet),
      );
      expect(sheet.onImageAttachment, isNull);
      expect(sheet.onCameraCapture, isNull);
    },
  );
}
