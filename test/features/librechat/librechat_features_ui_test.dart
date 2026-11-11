import 'dart:async';

import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_sync_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/features/librechat/services/librechat_provenance.dart';
import 'package:conduit_core/features/librechat/services/librechat_sync_engine.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/native.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Keeps a signed-in LibreChat session in memory.
final class _MemoryStore implements LibreChatSessionStore {
  LibreChatSession? session;

  @override
  Future<LibreChatSession?> read() async => session;

  @override
  Future<void> write(LibreChatSession value) async => session = value;

  @override
  Future<void> clear() async => session = null;
}

/// A signed-in LibreChat account on a fake server that copies every chat
/// into `lc-copy`, and the engine that stores the copy, as Duplicate needs.
typedef _CopyRig = ({
  LibreChatApiService api,
  LibreChatSyncEngine engine,
  Future<void> Function() close,
});

Future<_CopyRig> _copyRig() async {
  const server = LibreChatServer(baseUrl: 'https://chat.example.com');
  final fake = FakeLibreChatServer()..addUser();
  final now = DateTime.now().toUtc().toIso8601String();
  fake.on(
    'POST',
    '/api/convos/duplicate',
    (request, match) => FakeLibreChatResponse.json({
      'conversation': {
        'conversationId': 'lc-copy',
        'title': 'Paris weather (copy)',
        'createdAt': now,
        'updatedAt': now,
      },
      'messages': <Object>[],
    }),
  );
  final auth = LibreChatAuthService(server, adapter: fake);
  final signedIn =
      await auth.signIn(email: 'dev@example.com', password: 'devpassword')
          as LibreChatSignedIn;
  final handle = LibreChatSessionHandle(
    session: signedIn.session,
    store: _MemoryStore(),
    renew: auth.renew,
  );
  final client = LibreChatHttpClient(
    server: server,
    session: handle,
    adapter: fake,
  );
  final db = AppDatabase(NativeDatabase.memory());
  final api = LibreChatApiService(client);
  final engine = LibreChatSyncEngine(db: db, api: api);
  return (
    api: api,
    engine: engine,
    close: () async {
      engine.close();
      client.close();
      auth.close();
      await handle.dispose();
      await db.close();
    },
  );
}

/// Opening a chat ends as [result] says.
final class _Selection extends ConversationSelection {
  _Selection(this.result);

  final ConversationSelectionResult result;

  @override
  Future<ConversationSelectionResult> select(Conversation summary) async =>
      result;
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

void main() {
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
      Conversation? chat,
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
                  conversation: chat ?? conversation,
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
      expect(allowed, contains('Share Chat'));
      expect(allowed, contains('Duplicate Chat'));
      expect(allowed, isNot(contains('Move')));
    });

    testWidgets('hides sharing when the server refuses links', (tester) async {
      final refused = await labels(tester, const LibreChatCapabilities());
      expect(refused, isNot(contains('Share Chat')));
    });

    testWidgets('a chat with a link keeps sharing, to delete it', (
      tester,
    ) async {
      final refused = await labels(
        tester,
        const LibreChatCapabilities(),
        chat: conversation.copyWith(shareId: 'web'),
      );
      expect(refused, contains('Share Chat'));
    });

    Future<void> duplicate(
      WidgetTester tester,
      ConversationSelectionResult result,
    ) async {
      final rig = (await tester.runAsync(_copyRig))!;
      addTearDown(rig.close);
      late ConduitContextMenuAction action;
      await tester.pumpWidget(
        _app(
          overrides: [
            libreChatCapabilitiesProvider.overrideWith(
              (ref) async => const LibreChatCapabilities(sharedLinks: true),
            ),
            isOnlineProvider.overrideWithValue(true),
            libreChatApiServiceProvider.overrideWithValue(rig.api),
            libreChatSyncEngineProvider.overrideWithValue(rig.engine),
            conversationSelectionProvider.overrideWith(
              () => _Selection(result),
            ),
          ],
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                ref.watch(libreChatCapabilitiesProvider);
                action = buildConversationActionsWithFolders(
                  context: context,
                  ref: ref,
                  conversation: conversation,
                  foldersEnabled: true,
                  folders: const [],
                ).firstWhere((action) => action.label == 'Duplicate Chat');
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The copy is made on the (fake) server and stored for real, outside
      // the test's fake clock. The error dialog holds the action open until
      // it is dismissed.
      await tester.runAsync(() async {
        unawaited(action.onSelected());
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('a copy that cannot be opened says so', (tester) async {
      await duplicate(
        tester,
        ConversationSelectionResult.failed(
          StateError('gone'),
          StackTrace.empty,
        ),
      );
      expect(
        find.text(lookupAppLocalizations(const Locale('en')).libreChatCopyFailed),
        findsOneWidget,
      );
    });

    testWidgets('another chat chosen meanwhile is no failure', (tester) async {
      await duplicate(tester, const ConversationSelectionResult.canceled());
      expect(
        find.text(lookupAppLocalizations(const Locale('en')).libreChatCopyFailed),
        findsNothing,
      );
    });

    testWidgets('duplicating needs a connection', (tester) async {
      final offline = await labels(
        tester,
        const LibreChatCapabilities(sharedLinks: true),
        online: false,
      );
      expect(offline, isNot(contains('Duplicate Chat')));
    });
  });
}
