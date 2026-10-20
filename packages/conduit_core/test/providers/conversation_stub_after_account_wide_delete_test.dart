import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _QuietSyncEngine extends SyncEngine {
  @override
  Future<PullResult?> requestPull({required String reason}) =>
      Future<PullResult?>.value(null);
}

Conversation _conversation(String id) => withChatStorageProvenance(
  Conversation(
    id: id,
    title: 'Chat $id',
    createdAt: DateTime.utc(2026, 3, 1),
    updatedAt: DateTime.utc(2026, 3, 2),
  ),
  ChatStorageKind.openWebUi,
);

void main() {
  late AppDatabase db;
  late AppDatabase directDb;
  late bool previousWarning;

  setUpAll(() {
    previousWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning;
  });

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    directDb = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    await directDb.close();
  });

  ProviderContainer open() {
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(_QuietSyncEngine.new),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> seed(String id) => db.chatsDao.upsertServerChat(
    rows: ChatBlobMapper.blobToRows(
      chatId: id,
      title: id,
      createdAt: 1,
      updatedAt: 2,
      blob: <String, dynamic>{
        'title': id,
        'history': {'messages': {}},
      },
    ),
  );

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('an optimistic stub queued before an account-wide delete ended does '
      'not bring the chat back', () async {
    final container = open();
    await container.read(conversationsProvider.future);
    final locks = container.read(chatLocksProvider);
    await seed('x');
    final hold = Completer<void>();

    // The delete is running when the list writes its optimistic stub for the
    // chat, so the write waits behind it and runs after the chat is gone.
    final deleting = locks.runBarrier(() async {
      await hold.future;
      await db.chatsDao.purgeServerWideChats('me');
    });
    container
        .read(conversationsProvider.notifier)
        .upsertConversation(_conversation('x'));
    await settle();
    hold.complete();
    await deleting;
    await settle();

    check(await db.chatsDao.getChat('x')).isNull();
  });

  test('a stub written after the delete is stored as usual', () async {
    final container = open();
    await container.read(conversationsProvider.future);
    final locks = container.read(chatLocksProvider);
    await locks.runBarrier(() async {});

    container
        .read(conversationsProvider.notifier)
        .upsertConversation(_conversation('new'));
    await settle();

    check(await db.chatsDao.getChat('new')).isNotNull();
  });
}
