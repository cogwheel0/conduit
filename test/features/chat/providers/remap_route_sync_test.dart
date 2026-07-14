import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:drift/drift.dart' show Value;
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
import '../../../support/openwebui_storage_test_overrides.dart';

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

  ProviderContainer makeContainer({bool apiUnavailable = false}) {
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        apiServiceProvider.overrideWith(
          (ref) => apiUnavailable
              ? throw StateError('API context unavailable')
              : null,
        ),
        reviewerModeProvider.overrideWithValue(false),
        syncApiClientProvider.overrideWith((ref) => client),
        isAuthenticatedProvider2.overrideWith((ref) => true),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  IdRemapper remapperOf(ProviderContainer container) {
    final remapper = container
        .read(syncEngineProvider.notifier)
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
    await _runRemapAndWait(
      remapperOf(container),
      (remapper) => remapper.remapChat(
        localId: localId,
        serverId: 'server-1',
        serverCreatedAt: 1,
        serverUpdatedAt: 1,
      ),
    );
    await _waitUntil(
      () => container.read(activeConversationProvider)?.id == 'server-1',
    );

    check(container.read(activeConversationProvider)?.id).equals('server-1');
  });

  test('chat remap leaves a DIFFERENT active conversation untouched', () async {
    final container = makeContainer();
    container.read(remapRouteSyncProvider);

    container.read(activeConversationProvider.notifier).set(conv('other'));

    await _seedBareLocalChat(db, 'local:swap2');
    await _runRemapAndWait(
      remapperOf(container),
      (remapper) => remapper.remapChat(
        localId: 'local:swap2',
        serverId: 'server-2',
        serverCreatedAt: 1,
        serverUpdatedAt: 1,
      ),
    );

    check(container.read(activeConversationProvider)?.id).equals('other');
  });

  test('folder remap swaps the pending folder id in place', () async {
    final container = makeContainer();
    container.read(remapRouteSyncProvider);

    const localFolder = 'local:f1';
    container.read(pendingFolderIdProvider.notifier).set(localFolder);

    await _seedBareLocalFolder(db, localFolder);
    await _runRemapAndWait(
      remapperOf(container),
      (remapper) => remapper.remapFolder(
        localId: localFolder,
        serverId: 'srv-folder',
        serverUpdatedAt: 1,
      ),
    );
    await _waitUntil(
      () => container.read(pendingFolderIdProvider) == 'srv-folder',
    );

    check(container.read(pendingFolderIdProvider)).equals('srv-folder');
  });

  test('active id remap survives a failing context provider', () {
    final container = makeContainer(apiUnavailable: true);
    container
        .read(activeConversationProvider.notifier)
        .set(conv('local:context-failure'));

    check(
      () => container
          .read(activeConversationProvider.notifier)
          .remapIdInPlace(
            fromId: 'local:context-failure',
            toId: 'server-context-failure',
          ),
    ).returnsNormally();
    check(
      container.read(activeConversationProvider)?.id,
    ).equals('server-context-failure');
  });

  test('note route remap preserves query params', () {
    check(
      remappedNoteRouteForTesting(
        '/notes/local%3An1?mode=edit',
        fromId: 'local:n1',
        toId: 'server-note-1',
      ),
    ).equals('/notes/server-note-1?mode=edit');

    check(
      remappedNoteRouteForTesting(
        '/notes/other?mode=edit',
        fromId: 'local:n1',
        toId: 'server-note-1',
      ),
    ).isNull();
  });

  test('folder route remap preserves query params', () {
    check(
      remappedFolderRouteForTesting(
        '/folder/local%3Af1?view=grid',
        fromId: 'local:f1',
        toId: 'srv-folder',
      ),
    ).equals('/folder/srv-folder?view=grid');

    check(
      remappedFolderRouteForTesting(
        '/folder/other?view=grid',
        fromId: 'local:f1',
        toId: 'srv-folder',
      ),
    ).isNull();
  });
}

Future<void> _runRemapAndWait(
  IdRemapper remapper,
  Future<void> Function(IdRemapper remapper) run,
) async {
  final delivered = Completer<void>();
  late final StreamSubscription<RemapEvent> sub;
  sub = remapper.remapEvents.listen((_) {
    if (!delivered.isCompleted) {
      delivered.complete();
    }
  });
  try {
    await run(remapper);
    await delivered.future.timeout(const Duration(seconds: 2));
  } finally {
    await sub.cancel();
  }
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _seedBareLocalChat(AppDatabase db, String id) async {
  await db
      .into(db.chats)
      .insert(
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
  await db
      .into(db.folders)
      .insert(
        FoldersCompanion.insert(
          id: id,
          name: 'F',
          createdAt: 1,
          updatedAt: 1,
          dirty: const Value(true),
        ),
      );
}
