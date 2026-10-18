import 'package:conduit/features/profile/views/personalization_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/models/librechat_prompts.dart';
import 'package:conduit_core/features/librechat/providers/librechat_memories_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_provenance.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final class _NoModels extends Models {
  @override
  Future<List<Model>> build() async => const [];
}

/// Memories kept in the test, standing in for the server.
final class _FakeMemories extends LibreChatMemoriesController {
  _FakeMemories(this.saved, {this.refusal});

  final Map<String, String> saved;
  final String? refusal;
  final List<({String? originalKey, String key, String value})> saves = [];

  @override
  Future<LibreChatMemoryState> build() async => LibreChatMemoryState(
    memories: LibreChatMemories(
      memories: [
        for (final entry in saved.entries)
          LibreChatMemory(key: entry.key, value: entry.value, tokenCount: 5),
      ],
      totalTokens: saved.length * 5,
      tokenLimit: 20,
    ),
    enabled: true,
  );

  @override
  Future<void> save({
    String? originalKey,
    required String key,
    required String value,
  }) async {
    saves.add((originalKey: originalKey, key: key, value: value));
    final refusal = this.refusal;
    if (refusal != null) throw LibreChatApiException(message: refusal);
    saved
      ..remove(originalKey)
      ..[key] = value;
    ref.invalidateSelf();
  }
}

Widget _app({required List<Override> overrides, required Widget home}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

List<Override> _libreChatInCharge(LibreChatCapabilities capabilities) => [
  openWebUiAccountAvailableProvider.overrideWithValue(false),
  appSettingsProvider.overrideWithValue(const AppSettings()),
  apiServiceProvider.overrideWithValue(null),
  modelsProvider.overrideWith(_NoModels.new),
  primaryAccountKindProvider.overrideWithValue(PrimaryAccountKind.libreChat),
  libreChatCapabilitiesProvider.overrideWith((ref) async => capabilities),
];

Future<void> _openManager(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Manage memories'));
  await tester.tap(find.text('Manage memories'));
  await tester.pumpAndSettle();
}

Finder _keyField() => find.descendant(
  of: find.byKey(const Key('librechat-memory-key')),
  matching: find.byType(TextField),
);

void main() {
  group('LibreChat memories', () {
    testWidgets('show with their budget, and a new one saves by key', (
      tester,
    ) async {
      final memories = _FakeMemories({'work': 'Engineer'});
      await tester.pumpWidget(
        _app(
          overrides: [
            ..._libreChatInCharge(
              const LibreChatCapabilities(memories: true, createMemories: true),
            ),
            libreChatMemoriesProvider.overrideWith(() => memories),
          ],
          home: const PersonalizationPage(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('librechat-memories')), findsOneWidget);
      expect(find.text('5 of 20 tokens used'), findsOneWidget);
      await _openManager(tester);
      expect(find.byKey(const Key('librechat-memory-usage')), findsOneWidget);
      expect(find.text('work'), findsOneWidget);
      expect(find.text('Engineer'), findsOneWidget);

      await tester.tap(find.text('Add memory').last);
      await tester.pumpAndSettle();
      await tester.enterText(_keyField(), 'tone');
      final content = find.byType(TextField).evaluate().firstWhere(
        (element) => !_keyField().evaluate().contains(element),
      );
      await tester.enterText(find.byWidget(content.widget), 'Concise');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(memories.saves.single.key, 'tone');
      expect(memories.saves.single.value, 'Concise');
      expect(memories.saves.single.originalKey, isNull);
    });

    testWidgets('a refusal shows the server\'s reason in the editor', (
      tester,
    ) async {
      final memories = _FakeMemories(
        {'work': 'Engineer'},
        refusal: 'Memory with this key already exists.',
      );
      await tester.pumpWidget(
        _app(
          overrides: [
            ..._libreChatInCharge(
              const LibreChatCapabilities(memories: true, createMemories: true),
            ),
            libreChatMemoriesProvider.overrideWith(() => memories),
          ],
          home: const PersonalizationPage(),
        ),
      );
      await tester.pumpAndSettle();
      await _openManager(tester);
      await tester.tap(find.text('work'));
      await tester.pumpAndSettle();
      await tester.enterText(_keyField(), 'job');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(memories.saves.single.originalKey, 'work');
      expect(find.text('Memory with this key already exists.'), findsOneWidget);
    });

    testWidgets('hidden when the server does not offer memories', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          overrides: [
            ..._libreChatInCharge(const LibreChatCapabilities()),
            libreChatMemoriesProvider.overrideWith(() => _FakeMemories({})),
          ],
          home: const PersonalizationPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('librechat-memories')), findsNothing);
      expect(find.text('Manage memories'), findsNothing);
    });
  });

  group('LibreChat chat menu', () {
    final conversation = withChatStorageProvenance(
      stampLibreChatProvenance(
        Conversation(
          id: 'lc-1',
          title: 'Paris weather',
          createdAt: DateTime(2026, 10, 18),
          updatedAt: DateTime(2026, 10, 18),
        ),
      ),
      ChatStorageKind.libreChat,
    );

    Future<List<String>> labels(
      WidgetTester tester,
      LibreChatCapabilities capabilities, {
      bool online = true,
    }) async {
      late List<String> result;
      await tester.pumpWidget(
        _app(
          overrides: [
            libreChatCapabilitiesProvider.overrideWith(
              (ref) async => capabilities,
            ),
            isOnlineProvider.overrideWithValue(online),
          ],
          home: Consumer(
            builder: (context, ref, _) {
              // Read once the capabilities have loaded.
              ref.watch(libreChatCapabilitiesProvider);
              result = [
                for (final action in buildConversationActionsWithFolders(
                  context: context,
                  ref: ref,
                  conversation: conversation,
                  foldersEnabled: true,
                  folders: const [],
                ))
                  action.label,
              ];
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('offers sharing when the server allows links', (tester) async {
      final allowed = await labels(
        tester,
        const LibreChatCapabilities(sharedLinks: true),
      );
      expect(allowed, contains('Share chat'));
      expect(allowed, contains('Duplicate chat'));
      expect(allowed, isNot(contains('Move')));
    });

    testWidgets('hides sharing when the server refuses links', (tester) async {
      final refused = await labels(tester, const LibreChatCapabilities());
      expect(refused, isNot(contains('Share chat')));
    });

    testWidgets('duplicating needs a connection', (tester) async {
      final offline = await labels(
        tester,
        const LibreChatCapabilities(sharedLinks: true),
        online: false,
      );
      expect(offline, isNot(contains('Duplicate chat')));
    });
  });
}
