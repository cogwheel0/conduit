import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/providers/remap_route_sync_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_open_webui_server.dart';
import '../../../support/fake_sync_api_client.dart';

/// Wiring C: when a `local:` id is remapped, the active-chat / pending-folder
/// id must follow IN PLACE (no nav, no visible rebuild — NON-NEGOTIABLE 6).
///
/// The engine owns the single [IdRemapper] and surfaces it via [remapEvents];
/// the real `remapRouteSyncProvider` listens there. The tests drive a real,
/// committed remap through that SAME engine remapper and assert the swap.
void main() {
  late AppDatabase db;
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    server = FakeOpenWebUiServer();
    client = FakeSyncApiClient(server);
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        syncApiClientProvider.overrideWith((ref) => client),
        isAuthenticatedProvider2.overrideWith((ref) => true),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  IdRemapper remapperOf(ProviderContainer container) {
    final remapper = container.read(syncEngineProvider.notifier)
        .remapperForTesting;
    return remapper!;
  }

  Conversation conv(String id) => Conversation(
    id: id,
    title: 'C',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    messages: const [],
  );

  test('chat remap swaps the active conversation id in place', () async {
    final container = makeContainer();
    container.read(remapRouteSyncProvider); // install the real consumer.

    const localId = 'local:swap1';
    container.read(activeConversationProvider.notifier).set(conv(localId));

    await _seedBareLocalChat(db, localId);
    await remapperOf(container).remapChat(
      localId: localId,
      serverId: 'server-1',
      serverCreatedAt: 1,
      serverUpdatedAt: 1,
    );
    await Future<void>.delayed(Duration.zero);

    check(container.read(activeConversationProvider)?.id).equals('server-1');
  });

  test('chat remap leaves a DIFFERENT active conversation untouched', () async {
    final container = makeContainer();
    container.read(remapRouteSyncProvider);

    container.read(activeConversationProvider.notifier).set(conv('other'));

    await _seedBareLocalChat(db, 'local:swap2');
    await remapperOf(container).remapChat(
      localId: 'local:swap2',
      serverId: 'server-2',
      serverCreatedAt: 1,
      serverUpdatedAt: 1,
    );
    await Future<void>.delayed(Duration.zero);

    check(container.read(activeConversationProvider)?.id).equals('other');
  });

  test('folder remap swaps the pending folder id in place', () async {
    final container = makeContainer();
    container.read(remapRouteSyncProvider);

    const localFolder = 'local:f1';
    container.read(pendingFolderIdProvider.notifier).set(localFolder);

    await _seedBareLocalFolder(db, localFolder);
    await remapperOf(container).remapFolder(
      localId: localFolder,
      serverId: 'srv-folder',
      serverUpdatedAt: 1,
    );
    await Future<void>.delayed(Duration.zero);

    check(container.read(pendingFolderIdProvider)).equals('srv-folder');
  });
}

Future<void> _seedBareLocalChat(AppDatabase db, String id) async {
  await db.into(db.chats).insert(
    ChatsCompanion.insert(
      id: id,
      title: 'T',
      createdAt: 1,
      updatedAt: 1,
      dirty: const Value(true),
      bodySynced: const Value(true),
    ),
  );
}

Future<void> _seedBareLocalFolder(AppDatabase db, String id) async {
  await db.into(db.folders).insert(
    FoldersCompanion.insert(
      id: id,
      name: 'F',
      createdAt: 1,
      updatedAt: 1,
      dirty: const Value(true),
    ),
  );
}
