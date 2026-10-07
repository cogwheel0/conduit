import 'package:checks/checks.dart';
import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_data_controls.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
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

final class _Settings extends AppSettingsNotifier {
  _Settings(this._settings);

  final AppSettings _settings;

  @override
  AppSettings build() => _settings;
}

final class _QuietSyncEngine extends SyncEngine {
  final pulls = <String>[];

  @override
  Future<PullResult?> requestPull({required String reason}) {
    pulls.add(reason);
    return Future<PullResult?>.value(null);
  }
}

const _server = ServerConfig(
  id: 'server',
  name: 'Home server',
  url: 'https://example.test',
);

const _ava = User(
  id: 'user-1',
  username: 'ava',
  email: 'ava@example.com',
  name: 'Ava',
  role: 'user',
);

Conversation _conversation(
  String id, {
  bool archived = false,
  String? shareId,
  ChatStorageKind? storage = ChatStorageKind.openWebUi,
}) {
  final conversation = Conversation(
    id: id,
    title: 'Chat $id',
    createdAt: DateTime.utc(2026, 3, 1),
    updatedAt: DateTime.utc(2026, 3, 1),
    archived: archived,
    shareId: shareId,
    messages: [
      ChatMessage(
        id: 'm-$id',
        role: 'user',
        content: 'hello',
        timestamp: DateTime.utc(2026, 3, 1),
      ),
    ],
  );
  return storage == null
      ? conversation
      : withChatStorageProvenance(conversation, storage);
}

void main() {
  late AppDatabase db;
  late bool previousWarning;

  setUpAll(() {
    previousWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning;
  });

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  var epoch = Object();
  User? user = _ava;
  ApiService? api;
  var settings = const AppSettings(advancedFeaturesEnabled: true);
  Map<String, dynamic> permissions = const {};
  Object? permissionsFailure;

  setUp(() {
    epoch = Object();
    user = _ava;
    settings = const AppSettings(advancedFeaturesEnabled: true);
    permissions = const {};
    permissionsFailure = null;
    api = ApiService(serverConfig: _server, workerManager: WorkerManager());
  });
  tearDown(() => api?.dispose());

  ProviderContainer containerWith() {
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        appSettingsProvider.overrideWith(() => _Settings(settings)),
        apiServiceProvider.overrideWithValue(api),
        currentUserProvider2.overrideWith((ref) => user),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        socketServiceProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(_QuietSyncEngine.new),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
        userPermissionsProvider.overrideWith((ref) async {
          final failure = permissionsFailure;
          if (failure != null) throw failure;
          return permissions;
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('the account a surface was opened for', () {
    test('is captured with the names the user is shown', () {
      final container = containerWith();

      final owner = captureChatDataControlsOwner(container)!;

      check(owner.accountName).equals('Ava');
      check(owner.serverName).equals('Home server');
      check(owner.accountId).equals('user-1');
      check(chatDataControlsOwnerIsCurrent(container, owner)).isTrue();
    });

    test('is nobody without an Open WebUI account', () {
      api = null;
      check(captureChatDataControlsOwner(containerWith())).isNull();
      api = ApiService(serverConfig: _server, workerManager: WorkerManager());
      user = null;
      check(captureChatDataControlsOwner(containerWith())).isNull();
    });

    test('stops being current when the session or the account changes', () {
      final container = containerWith();
      final owner = captureChatDataControlsOwner(container)!;

      epoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      check(chatDataControlsOwnerIsCurrent(container, owner)).isFalse();

      final next = containerWith();
      final nextOwner = captureChatDataControlsOwner(next)!;
      user = const User(
        id: 'user-2',
        username: 'bo',
        email: 'bo@example.com',
        role: 'user',
      );
      next.invalidate(currentUserProvider2);
      check(chatDataControlsOwnerIsCurrent(next, nextOwner)).isFalse();
    });
  });

  group('who sees the entry and the actions', () {
    test('the page entry needs Advanced and a signed-in account', () {
      check(containerWith().read(chatDataControlsEntryVisibleProvider))
          .isTrue();

      settings = const AppSettings();
      check(containerWith().read(chatDataControlsEntryVisibleProvider))
          .isFalse();

      settings = const AppSettings(advancedFeaturesEnabled: true);
      user = null;
      check(containerWith().read(chatDataControlsEntryVisibleProvider))
          .isFalse();
    });

    test(
      'an action is allowed unless the account is explicitly denied it',
      () async {
        Future<bool> allowed(String action) => containerWith().read(
          openWebUiChatActionAllowedProvider(action).future,
        );

        check(await allowed('export')).isTrue();
        permissions = {
          'chat': {'import': false, 'export': true},
        };
        check(await allowed('import')).isFalse();
        check(await allowed('export')).isTrue();
        // Not reported means the server's default, which is allowed.
        check(await allowed('delete')).isTrue();
      },
    );

    test(
      'an admin is always allowed, and an unreadable set grants nothing',
      () async {
        permissions = {
          'chat': {'import': false},
        };
        user = const User(
          id: 'admin',
          username: 'root',
          email: 'root@example.com',
          role: 'admin',
        );
        check(
          await containerWith().read(
            openWebUiChatActionAllowedProvider('import').future,
          ),
        ).isTrue();

        user = _ava;
        permissionsFailure = StateError('offline');
        check(
          await containerWith().read(
            openWebUiChatActionAllowedProvider('export').future,
          ),
        ).isFalse();
      },
    );

    test(
      'Export is offered for an Open WebUI chat and not for on-device ones',
      () async {
        final container = containerWith();
        await container.read(
          openWebUiChatActionAllowedProvider('export').future,
        );
        final active = container.read(activeConversationProvider.notifier);

        check(container.read(chatExportAvailableProvider)).isFalse();
        active.set(_conversation('chat-a'));
        check(container.read(chatExportAvailableProvider)).isTrue();
        active.set(
          _conversation('chat-a', storage: ChatStorageKind.directLocal),
        );
        check(container.read(chatExportAvailableProvider)).isFalse();

        permissions = {
          'chat': {'export': false},
        };
        final denied = containerWith();
        await denied.read(openWebUiChatActionAllowedProvider('export').future);
        denied
            .read(activeConversationProvider.notifier)
            .set(_conversation('c'));
        check(denied.read(chatExportAvailableProvider)).isFalse();
      },
    );
  });

  group('applyChatBulkOutcome', () {
    ProviderContainer open(Conversation active) {
      final container = containerWith();
      container.read(activeConversationProvider.notifier).set(active);
      container
          .read(chatMessagesProvider.notifier)
          .setMessages(active.messages);
      return container;
    }

    test('delete all leaves a chat that was deleted', () {
      final container = open(_conversation('chat-a'));
      final owner = captureChatDataControlsOwner(container)!;

      applyChatBulkOutcome(
        container,
        owner,
        ChatBulkChange.delete,
        const ChatBulkOutcome(changed: 2, removedChatIds: ['chat-a', 'other']),
      );

      check(container.read(activeConversationProvider)).isNull();
      check(container.read(chatMessagesProvider)).isEmpty();
    });

    test('delete all keeps a chat that was not deleted', () {
      for (final active in [
        _conversation('chat-z'),
        _conversation('local:abc'),
      ]) {
        final container = open(active);
        final owner = captureChatDataControlsOwner(container)!;

        applyChatBulkOutcome(
          container,
          owner,
          ChatBulkChange.delete,
          const ChatBulkOutcome(changed: 1, removedChatIds: ['chat-a']),
        );

        check(container.read(activeConversationProvider)?.id).equals(active.id);
        check(container.read(chatMessagesProvider)).isNotEmpty();
      }
    });

    test('archive all files the open chat away like archiving it by hand', () {
      final container = open(_conversation('chat-a'));
      final owner = captureChatDataControlsOwner(container)!;

      applyChatBulkOutcome(
        container,
        owner,
        ChatBulkChange.archive,
        const ChatBulkOutcome(changed: 1),
      );

      check(container.read(activeConversationProvider)).isNull();
    });

    test('unarchive and unshare only update the open chat\'s flags', () {
      final container = open(
        _conversation('chat-a', archived: true, shareId: 'share'),
      );
      final owner = captureChatDataControlsOwner(container)!;

      applyChatBulkOutcome(
        container,
        owner,
        ChatBulkChange.unarchive,
        const ChatBulkOutcome(changed: 1),
      );
      check(container.read(activeConversationProvider)!.archived).isFalse();
      check(container.read(activeConversationProvider)!.shareId)
          .equals('share');

      applyChatBulkOutcome(
        container,
        owner,
        ChatBulkChange.unshare,
        const ChatBulkOutcome(changed: 1),
      );
      check(container.read(activeConversationProvider)!.shareId).isNull();
      check(container.read(chatMessagesProvider)).isNotEmpty();
    });

    test('another account\'s result changes nothing on screen', () {
      final container = open(_conversation('chat-a'));
      final owner = captureChatDataControlsOwner(container)!;
      epoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);

      applyChatBulkOutcome(
        container,
        owner,
        ChatBulkChange.delete,
        const ChatBulkOutcome(changed: 1, removedChatIds: ['chat-a']),
      );

      check(container.read(activeConversationProvider)?.id).equals('chat-a');
    });
  });

  group('the stored chats an Open WebUI account owns', () {
    test('are what the service is built against', () async {
      final container = containerWith();
      final owner = captureChatDataControlsOwner(container)!;
      await db.chatsDao.upsertServerChat(
        rows: ChatBlobMapper.blobToRows(
          chatId: 's1',
          title: 's1',
          createdAt: 1,
          updatedAt: 2,
          blob: <String, dynamic>{
            'title': 's1',
            'history': {'messages': {}},
          },
        ),
        userId: 'user-1',
      );

      final scope = await chatDataControlsServiceForOwner(
        container,
        owner,
      ).scope();

      check(scope.serverChats).equals(1);
    });
  });
}
