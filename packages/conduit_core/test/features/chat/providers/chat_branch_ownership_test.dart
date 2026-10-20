/// Ownership and presentation contracts of the branch controller: continuing
/// from an alternative and forking at a message.
///
/// The harness uses the real [ChatMessagesNotifier], the real repository, real
/// Drift stores and the real per-chat locks, so the visible transcript is the
/// one the send path reads. Only the API and the sync engine are faked.
library;

import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_branch_service.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _EpochNotifier extends Notifier<Object> {
  @override
  Object build() => Object();

  /// A new sign-in session: a sign-out and back in, or another account.
  void rotate() => state = Object();
}

final _epochProvider = NotifierProvider<_EpochNotifier, Object>(
  _EpochNotifier.new,
);

final class _CountingSyncEngine extends SyncEngine {
  final drained = <AppDatabase>[];

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {
    drained.add(expectedDatabase);
  }

  @override
  Future<PullResult?> requestPull({required String reason}) async => null;
}

/// Records every request the branch controller makes of the server, and can
/// hold one open so a test changes the world while it is in flight.
final class _BranchApi extends ApiService {
  _BranchApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://server.example',
        ),
        workerManager: WorkerManager(),
      );

  final bodyLoads = <(String, ApiAuthSnapshot?)>[];
  final forks = <(String, String, ApiAuthSnapshot?)>[];
  var clones = 0;
  Completer<void>? bodyGate;
  Completer<void>? forkGate;
  Map<String, Map<String, dynamic>> envelopes = {};
  Object? forkError;
  Map<String, dynamic>? forkEnvelope;

  @override
  Future<Map<String, dynamic>?> getChatRaw(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    bodyLoads.add((id, authSnapshot));
    await bodyGate?.future;
    return envelopes[id];
  }

  @override
  Future<Map<String, dynamic>> forkChatRaw(
    String id,
    String messageId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    forks.add((id, messageId, authSnapshot));
    await forkGate?.future;
    final error = forkError;
    if (error != null) throw error;
    return forkEnvelope!;
  }

  @override
  Future<Conversation> cloneConversation(String id) async {
    clones++;
    throw StateError('a fork must never fall back to a clone');
  }

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async => const [];

  var stops = 0;

  @override
  Future<void> stopTasksByChat(String chatId) async {
    stops++;
  }
}

Map<String, dynamic> _message(
  String id, {
  String? parent,
  List<String> children = const <String>[],
  String role = 'user',
}) => <String, dynamic>{
  'id': id,
  'parentId': parent,
  'childrenIds': children,
  'role': role,
  'content': 'text of $id',
  'timestamp': 1,
  if (role == 'assistant') 'done': true,
};

/// u1 has two answers. a2 is the last and continues; a1 is the other answer.
/// An edited first message e1 is a root sibling of u1 with its own branch.
Map<String, dynamic> _branchedBlob({
  String currentId = 'a3',
}) => <String, dynamic>{
  'title': 'Branches',
  'params': <String, dynamic>{'temperature': 0.3},
  'futureEnvelopeKey': <String, dynamic>{'kept': true},
  'history': <String, dynamic>{
    'currentId': currentId,
    'messages': <String, dynamic>{
      'u1': _message('u1', children: ['a1', 'a2']),
      'a1': _message('a1', parent: 'u1', role: 'assistant'),
      'a2': _message('a2', parent: 'u1', role: 'assistant', children: ['u2']),
      'u2': _message('u2', parent: 'a2', children: ['a3']),
      'a3': _message('a3', parent: 'u2', role: 'assistant'),
      'e1': _message('e1', children: ['b1']),
      'b1': _message('b1', parent: 'e1', role: 'assistant'),
    },
  },
};

ChatRows _rows(Map<String, dynamic> blob, {String id = 'c1', int at = 1}) =>
    ChatBlobMapper.blobToRows(
      chatId: id,
      title: 'Branches',
      createdAt: 1,
      updatedAt: at,
      blob: blob,
    );

Map<String, dynamic> _envelope(
  Map<String, dynamic> blob, {
  required String id,
  String? folderId,
}) => <String, dynamic>{
  'id': id,
  'user_id': 'user-1',
  'title': 'Branches (fork)',
  'chat': blob,
  'updated_at': 50,
  'created_at': 50,
  'folder_id': folderId,
  'archived': false,
  'pinned': false,
  'meta': <String, dynamic>{'forked_from': 'c1'},
};

Future<Conversation> _loaded(AppDatabase db, String id) async {
  final chat = (await db.chatsDao.getChat(id))!;
  final rows = await db.messagesDao.getForChat(id);
  return withChatStorageProvenance(
    assembleConversation(chat, rows),
    ChatStorageKind.openWebUi,
  );
}

const _user = User(
  id: 'user-1',
  username: 'user',
  email: 'user@example.test',
  role: 'user',
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late AppDatabase db;
  late AppDatabase directDb;
  late _CountingSyncEngine engine;
  late _BranchApi api;
  late bool previousDontWarn;

  setUpAll(() {
    previousDontWarn = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(
    () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousDontWarn,
  );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    directDb = AppDatabase(NativeDatabase.memory());
    engine = _CountingSyncEngine();
    api = _BranchApi();
  });
  tearDown(() async {
    await db.close();
    await directDb.close();
  });

  ProviderContainer container({
    Conversation? active,
    bool online = true,
    User? user = _user,
    Future<Map<String, dynamic>> Function()? permissions,
    bool rotatingEpoch = false,
    List<Override> extra = const [],
  }) {
    final c = ProviderContainer(
      overrides: [
        ...extra,
        ...openWebUiStorageOpenOverrides(database: db),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        socketServiceProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(() => engine),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
        apiServiceProvider.overrideWithValue(api),
        currentUserProvider2.overrideWithValue(user),
        isOnlineProvider.overrideWithValue(online),
        // Advanced stays off: none of what is under test depends on it.
        appSettingsProvider.overrideWithValue(const AppSettings()),
        // Account-scoped like the real provider: a new sign-in session reads
        // its own permissions instead of inheriting the earlier one's.
        if (permissions != null)
          userPermissionsProvider.overrideWith((ref) {
            ref.watch(openWebUiAuthSessionEpochProvider);
            return permissions();
          }),
        if (rotatingEpoch)
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(_epochProvider),
          )
        else
          openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
      ],
    );
    addTearDown(c.dispose);
    // The real transcript owner, listening to the active conversation.
    c.read(chatMessagesProvider);
    if (active != null) {
      c.read(activeConversationProvider.notifier).set(active);
    }
    return c;
  }

  Future<void> seed({String id = 'c1', String currentId = 'a3'}) =>
      db.chatsDao.upsertServerChat(
        rows: _rows(_branchedBlob(currentId: currentId), id: id),
      );

  List<String> visibleIds(ProviderContainer c) =>
      c.read(chatMessagesProvider).map((m) => m.id).toList();

  Future<String?> storedLeaf(String id) async =>
      (await db.chatsDao.getChat(id))?.currentMessageId;

  group('continuing from an alternative', () {
    test('rebuilds the transcript on the chosen branch', () async {
      await seed();
      final c = container(active: await _loaded(db, 'c1'));
      check(visibleIds(c)).deepEquals(['u1', 'a2', 'u2', 'a3']);
      // The pager's alternative is known to the transcript by its real id.
      check(c.read(chatMessagesProvider).first.versions)
          .isEmpty(); // u1 has no edited sibling here.
      final answer = c.read(chatMessagesProvider)[1];
      check(answer.versions.map((v) => v.id)).deepEquals(['a1']);

      final selection = await selectChatBranch(
        c,
        conversation: c.read(activeConversationProvider)!,
        messageId: answer.versions.single.id,
        alternativeTo: answer.id,
      );
      await _settle();

      check(selection.leafId).equals('a1');
      // What the send path reads next: the parent of a new message is the
      // last visible id, and the request history is exactly root -> leaf.
      check(visibleIds(c)).deepEquals(['u1', 'a1']);
      check(c.read(activeConversationProvider)!.messages.map((m) => m.id))
          .deepEquals(['u1', 'a1']);
      // The other answer is now the alternative, and nothing was lost.
      check(c.read(chatMessagesProvider).last.versions.map((v) => v.id))
          .deepEquals(['a2']);
      check(await storedLeaf('c1')).equals('a1');
      check((await db.messagesDao.getForChat('c1'))).length.equals(7);
      check(engine.drained).length.equals(1);
      check(await db.outboxDao.hasPendingBranchEdit('c1')).isTrue();
    });

    test('an edited first message continues down its own branch', () async {
      await seed();
      final c = container(active: await _loaded(db, 'c1'));

      await selectChatBranch(
        c,
        conversation: c.read(activeConversationProvider)!,
        messageId: 'e1',
        alternativeTo: 'u1',
      );
      await _settle();

      check(visibleIds(c)).deepEquals(['e1', 'b1']);
      check(await storedLeaf('c1')).equals('b1');
    });

    test('survives a reload of the stored chat', () async {
      await seed();
      final c = container(active: await _loaded(db, 'c1'));
      await selectChatBranch(
        c,
        conversation: c.read(activeConversationProvider)!,
        messageId: 'a1',
        alternativeTo: 'a2',
      );

      final reopened = await _loaded(db, 'c1');

      check(reopened.messages.map((m) => m.id)).deepEquals(['u1', 'a1']);
      check(reopened.chatParams).deepEquals({'temperature': 0.3});
    });

    test('is refused while a response is running on the chat', () async {
      await seed();
      final c = container(active: await _loaded(db, 'c1'));
      final notifier = c.read(chatMessagesProvider.notifier);
      final streaming = c
          .read(chatMessagesProvider)
          .last
          .copyWith(isStreaming: true);
      notifier.setMessages([
        ...c.read(chatMessagesProvider).take(3),
        streaming,
      ]);

      await check(
        selectChatBranch(
          c,
          conversation: c.read(activeConversationProvider)!,
          messageId: 'a1',
          alternativeTo: 'a2',
        ),
      ).throws<ChatBranchException>(
        (e) => e
            .has((it) => it.reason, 'reason')
            .equals(ChatBranchFailure.responseRunning),
      );

      check(await storedLeaf('c1')).equals('a3');
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
      // Refusing never stops the response and never changes the transcript.
      check(api.stops).equals(0);
      check(visibleIds(c)).deepEquals(['u1', 'a2', 'u2', 'a3']);
    });

    test('another chat\'s running response does not block this chat', () async {
      await seed();
      await seed(id: 'c2');
      final c = container(active: await _loaded(db, 'c1'));
      // c2 is the chat streaming; it is not on screen.
      final other = await _loaded(db, 'c2');

      await selectChatBranch(
        c,
        conversation: c.read(activeConversationProvider)!,
        messageId: 'a1',
        alternativeTo: 'a2',
      );

      check(other.id).equals('c2');
      check(await storedLeaf('c1')).equals('a1');
      check(await storedLeaf('c2')).equals('a3');
    });

    test('an account switch before the write changes nothing', () async {
      await seed();
      final c = container(active: await _loaded(db, 'c1'), rotatingEpoch: true);
      final conversation = c.read(activeConversationProvider)!;
      final owner = captureChatMutationOwner(c, conversation);

      c.read(_epochProvider.notifier).rotate();

      await check(
        selectChatBranch(
          c,
          conversation: conversation,
          messageId: 'a1',
          alternativeTo: 'a2',
          owner: owner,
        ),
      ).throws<ChatBranchException>(
        (e) => e
            .has((it) => it.reason, 'reason')
            .equals(ChatBranchFailure.ownerChanged),
      );

      check(await storedLeaf('c1')).equals('a3');
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
      check(engine.drained).isEmpty();
    });

    test('an account switch while the body loads stores nothing', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'c1',
        title: 'Stub',
        createdAt: 1,
        updatedAt: 5,
      );
      api.envelopes['c1'] = _envelope(_branchedBlob(), id: 'c1');
      api.bodyGate = Completer<void>();
      final c = container(
        active: withChatStorageProvenance(
          Conversation(
            id: 'c1',
            title: 'Stub',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
          ChatStorageKind.openWebUi,
        ),
        rotatingEpoch: true,
      );

      final pending = selectChatBranch(
        c,
        conversation: c.read(activeConversationProvider)!,
        messageId: 'a1',
      );
      await _settle();
      // The read went out with the account's own credentials.
      check(api.bodyLoads).length.equals(1);
      check(api.bodyLoads.single.$2).isNotNull();
      c.read(_epochProvider.notifier).rotate();
      api.bodyGate!.complete();

      await check(pending).throws<ChatBranchException>(
        (e) => e
            .has((it) => it.reason, 'reason')
            .equals(ChatBranchFailure.ownerChanged),
      );
      check((await db.chatsDao.getChat('c1'))!.bodySynced).isFalse();
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });

    test(
      'moving to another chat mid-operation keeps that chat on screen',
      () async {
        await db.chatsDao.upsertEnvelopeStub(
          id: 'c1',
          title: 'Stub',
          createdAt: 1,
          updatedAt: 5,
        );
        await seed(id: 'c2');
        api.envelopes['c1'] = _envelope(_branchedBlob(), id: 'c1');
        api.bodyGate = Completer<void>();
        final c = container(
          active: withChatStorageProvenance(
            Conversation(
              id: 'c1',
              title: 'Stub',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
            ChatStorageKind.openWebUi,
          ),
        );
        final pending = selectChatBranch(
          c,
          conversation: c.read(activeConversationProvider)!,
          messageId: 'a1',
        );
        await _settle();
        c
            .read(activeConversationProvider.notifier)
            .set(await _loaded(db, 'c2'));
        await _settle();

        api.bodyGate!.complete();
        await pending;
        await _settle();

        // The choice was made on c1 and is stored there...
        check(await storedLeaf('c1')).equals('a1');
        // ...but the chat on screen is still c2, and its branch is untouched.
        check(c.read(activeConversationProvider)!.id).equals('c2');
        check(visibleIds(c)).deepEquals(['u1', 'a2', 'u2', 'a3']);
      },
    );

    test('is not offered for chats the user may not change', () async {
      await seed();
      final shared = (await _loaded(db, 'c1')).copyWith(userId: 'someone-else');
      final temporary = (await _loaded(db, 'c1')).copyWith(id: 'local:tmp');
      final direct = withChatStorageProvenance(
        await _loaded(db, 'c1'),
        ChatStorageKind.directLocal,
      );

      for (final conversation in [shared, temporary, direct]) {
        final c = container(active: conversation);
        await check(
          selectChatBranch(
            c,
            conversation: conversation,
            messageId: 'a1',
            alternativeTo: 'a2',
          ),
        ).throws<ChatBranchException>(
          (e) => e
              .has((it) => it.reason, 'reason')
              .equals(ChatBranchFailure.unavailable),
        );
      }
      check(await storedLeaf('c1')).equals('a3');
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });
  });

  group('what the interface may offer', () {
    test(
      'the controls need a durable chat of the user\'s own, not Advanced',
      () async {
        await seed();
        final stored = await _loaded(db, 'c1');

        bool offered(ProviderContainer c) => c.read(chatBranchControlsProvider);

        check(offered(container(active: stored))).isTrue();
        check(offered(container())).isFalse();
        check(
          offered(container(active: stored.copyWith(userId: 'someone-else'))),
        ).isFalse();
        check(offered(container(active: stored.copyWith(id: 'local:t'))))
            .isFalse();
        check(
          offered(
            container(
              active: withChatStorageProvenance(
                stored,
                ChatStorageKind.directLocal,
              ),
            ),
          ),
        ).isFalse();
      },
    );

    test('saved branches stay readable where the controls are not offered',
        () async {
      await seed(currentId: 'a1');
      final stored = await _loaded(db, 'c1');
      final c = container(active: stored.copyWith(userId: 'someone-else'));

      // The chosen branch and the pager's alternatives are both there.
      check(visibleIds(c)).deepEquals(['u1', 'a1']);
      check(c.read(chatMessagesProvider).last.versions.map((v) => v.id))
          .deepEquals(['a2']);
      check(c.read(chatBranchControlsProvider)).isFalse();
      check(
        await c.read(
          chatBranchSiblingsProvider((chatId: 'c1', messageId: 'a1')).future,
        ),
      ).isNull();
    });

    test(
      'a displayed version earns a continue action only by its real id',
      () async {
        await seed();
        final c = container(active: await _loaded(db, 'c1'));

        final siblings = await c.read(
          chatBranchSiblingsProvider((chatId: 'c1', messageId: 'a2')).future,
        );

        check(siblings).isNotNull();
        check(siblings!.ids).deepEquals(['a1', 'a2']);
        check(siblings.index).equals(1);
        check(siblings.contains('a1')).isTrue();
        // A version kept on the message itself has an id the graph never saw.
        check(siblings.contains('stored-in-message')).isFalse();
        // A message with nothing to choose between offers nothing.
        check(
          await c.read(
            chatBranchSiblingsProvider((chatId: 'c1', messageId: 'a3')).future,
          ),
        ).isNull();
      },
    );

    test('edited first messages are alternatives of each other', () async {
      await seed();
      final c = container(active: await _loaded(db, 'c1'));

      final siblings = await c.read(
        chatBranchSiblingsProvider((chatId: 'c1', messageId: 'u1')).future,
      );

      check(siblings!.ids).deepEquals(['u1', 'e1']);
    });

    test('the siblings follow a branch switch', () async {
      await seed();
      final c = container(active: await _loaded(db, 'c1'));
      c.listen(
        chatBranchSiblingsProvider((chatId: 'c1', messageId: 'a2')),
        (_, _) {},
      );
      check(
        (await c.read(
          chatBranchSiblingsProvider((chatId: 'c1', messageId: 'a2')).future,
        ))!.ids,
      ).deepEquals(['a1', 'a2']);

      await selectChatBranch(
        c,
        conversation: c.read(activeConversationProvider)!,
        messageId: 'a1',
        alternativeTo: 'a2',
      );
      await _settle();

      // a2 is no longer on the visible branch; a1 now is, with a2 beside it.
      check(
        (await c.read(
          chatBranchSiblingsProvider((chatId: 'c1', messageId: 'a1')).future,
        ))!.ids,
      ).deepEquals(['a1', 'a2']);
    });

    group('fork availability', () {
      Future<Map<String, dynamic>> allowed() async => {
        'chat': <String, dynamic>{'import': true},
      };

      Future<ChatForkAvailability> availability(ProviderContainer c) async {
        c.listen(openWebUiChatImportAllowedProvider, (_, _) {});
        await c.read(openWebUiChatImportAllowedProvider.future);
        return c.read(chatForkAvailabilityProvider);
      }

      test('needs chat.import, whose default is allowed', () async {
        await seed();
        final stored = await _loaded(db, 'c1');

        check(
          await availability(container(active: stored, permissions: allowed)),
        ).equals(ChatForkAvailability.available);
        check(
          await availability(
            container(
              active: stored,
              permissions: () async => {'chat': <String, dynamic>{}},
            ),
          ),
        ).equals(ChatForkAvailability.available);
        check(
          await availability(
            container(
              active: stored,
              permissions: () async => {
                'chat': <String, dynamic>{'import': false},
              },
            ),
          ),
        ).equals(ChatForkAvailability.hidden);
        // An unreadable permission set grants nothing.
        check(
          await availability(
            container(
              active: stored,
              permissions: () async => throw StateError('offline'),
            ),
          ),
        ).equals(ChatForkAvailability.hidden);
        // An admin needs no grant.
        check(
          await availability(
            container(
              active: stored,
              user: _user.copyWith(role: 'admin'),
              permissions: () async => {
                'chat': <String, dynamic>{'import': false},
              },
            ),
          ),
        ).equals(ChatForkAvailability.available);
      });

      test('is disabled while offline', () async {
        await seed();
        final stored = await _loaded(db, 'c1');

        check(
          await availability(
            container(active: stored, online: false, permissions: allowed),
          ),
        ).equals(ChatForkAvailability.offline);
      });

      test('is disabled while a response is running', () async {
        await seed();
        final c = container(
          active: await _loaded(db, 'c1'),
          permissions: allowed,
        );
        final messages = c.read(chatMessagesProvider);
        c.read(chatMessagesProvider.notifier).setMessages([
          ...messages.take(3),
          messages.last.copyWith(isStreaming: true),
        ]);

        check(await availability(c))
            .equals(ChatForkAvailability.responseRunning);
      });

      test(
        'a late grant for an earlier account never reaches the next',
        () async {
          await seed();
          // Account A's permission read is slow and would grant import; account
          // B, who signs in meanwhile, is not allowed to.
          final accountA = Completer<Map<String, dynamic>>();
          var reads = 0;
          final c = container(
            active: await _loaded(db, 'c1'),
            permissions: () {
              reads++;
              return reads == 1
                  ? accountA.future
                  : Future.value(<String, dynamic>{
                      'chat': <String, dynamic>{'import': false},
                    });
            },
            rotatingEpoch: true,
          );
          c.listen(openWebUiChatImportAllowedProvider, (_, _) {});
          final pending = c.read(openWebUiChatImportAllowedProvider.future);

          c.read(_epochProvider.notifier).rotate();
          accountA.complete({
            'chat': <String, dynamic>{'import': true},
          });

          check(await pending).isFalse();
          check(c.read(chatForkAvailabilityProvider))
              .equals(ChatForkAvailability.hidden);
        },
      );
    });
  });

  group('forking at a message', () {
    Map<String, dynamic> forkBlob() => <String, dynamic>{
      'title': 'Branches (fork)',
      'params': <String, dynamic>{'temperature': 0.3},
      'originalChatId': 'c1',
      'history': <String, dynamic>{
        'currentId': 'a1',
        'messages': <String, dynamic>{
          'u1': _message('u1', children: ['a1']),
          'a1': _message('a1', parent: 'u1', role: 'assistant'),
        },
      },
    };

    Future<Map<String, dynamic>> allowed() async => {
      'chat': <String, dynamic>{'import': true},
    };

    test(
      'sends the real id once, stores the answer and opens the new chat',
      () async {
        await seed();
        api.forkEnvelope = _envelope(forkBlob(), id: 'fork-1', folderId: 'f9');
        final c = container(
          active: await _loaded(db, 'c1'),
          permissions: allowed,
        );

        final result = await forkChatAtMessage(
          c,
          conversation: c.read(activeConversationProvider)!,
          messageId: 'a1',
        );
        await _settle();

        check(result.chatId).equals('fork-1');
        check(result.opened).isTrue();
        check(api.forks.map((f) => (f.$1, f.$2))).deepEquals([('c1', 'a1')]);
        check(api.forks.single.$3).isNotNull();
        check(api.clones).equals(0);
        final stored = (await db.chatsDao.getChat('fork-1'))!;
        check(stored.folderId).equals('f9');
        check(stored.title).equals('Branches (fork)');
        check(jsonDecode(stored.rawExtra) as Map).containsKey('originalChatId');
        check(await db.chatsDao.getChatParams('fork-1'))
            .isNotNull()
            .deepEquals({'temperature': 0.3});
        // The new chat is open, the old one is exactly as it was.
        check(c.read(activeConversationProvider)!.id).equals('fork-1');
        check(visibleIds(c)).deepEquals(['u1', 'a1']);
        check((await db.messagesDao.getForChat('c1'))).length.equals(7);
        check(await storedLeaf('c1')).equals('a3');
        check(await db.outboxDao.pendingForChat('fork-1')).isEmpty();
      },
    );

    test(
      'a delayed answer after an account switch stores and opens nothing',
      () async {
        await seed();
        api.forkEnvelope = _envelope(forkBlob(), id: 'fork-late');
        api.forkGate = Completer<void>();
        final c = container(
          active: await _loaded(db, 'c1'),
          permissions: allowed,
          rotatingEpoch: true,
        );
        final pending = forkChatAtMessage(
          c,
          conversation: c.read(activeConversationProvider)!,
          messageId: 'a1',
        );
        await _settle();
        check(api.forks).length.equals(1);

        c.read(_epochProvider.notifier).rotate();
        api.forkGate!.complete();

        await check(pending).throws<ChatBranchException>(
          (e) => e
              .has((it) => it.reason, 'reason')
              .equals(ChatBranchFailure.ownerChanged),
        );
        await _settle();
        check(await db.chatsDao.getChat('fork-late')).isNull();
        check(c.read(activeConversationProvider)!.id).equals('c1');
        check(api.forks).length.equals(1);
      },
    );

    test(
      'moving to another chat meanwhile stores the fork but does not open it',
      () async {
        await seed();
        await seed(id: 'c2');
        api.forkEnvelope = _envelope(forkBlob(), id: 'fork-1');
        api.forkGate = Completer<void>();
        final c = container(
          active: await _loaded(db, 'c1'),
          permissions: allowed,
        );
        final pending = forkChatAtMessage(
          c,
          conversation: c.read(activeConversationProvider)!,
          messageId: 'a1',
        );
        await _settle();
        c
            .read(activeConversationProvider.notifier)
            .set(await _loaded(db, 'c2'));
        await _settle();

        api.forkGate!.complete();
        final result = await pending;
        await _settle();

        check(result.opened).isFalse();
        check(await db.chatsDao.getChat('fork-1')).isNotNull();
        check(c.read(activeConversationProvider)!.id).equals('c2');
      },
    );

    test(
      'each refusal is reported once, with no clone and nothing stored',
      () async {
        await seed();
        final cases = <ChatBranchFailure, DioException>{
          ChatBranchFailure.forkForbidden: DioException(
            requestOptions: RequestOptions(path: '/x'),
            response: Response<Object?>(
              requestOptions: RequestOptions(path: '/x'),
              statusCode: 403,
            ),
          ),
          ChatBranchFailure.forkConflict: DioException(
            requestOptions: RequestOptions(path: '/x'),
            response: Response<Object?>(
              requestOptions: RequestOptions(path: '/x'),
              statusCode: 409,
            ),
          ),
          ChatBranchFailure.forkSourceMissing: DioException(
            requestOptions: RequestOptions(path: '/x'),
            response: Response<Object?>(
              requestOptions: RequestOptions(path: '/x'),
              statusCode: 401,
            ),
          ),
        };

        for (final entry in cases.entries) {
          api = _BranchApi()..forkError = entry.value;
          final c = container(
            active: await _loaded(db, 'c1'),
            permissions: allowed,
          );
          await check(
            forkChatAtMessage(
              c,
              conversation: c.read(activeConversationProvider)!,
              messageId: 'a1',
            ),
          ).throws<ChatBranchException>(
            (e) => e.has((it) => it.reason, 'reason').equals(entry.key),
          );
          check(api.forks).length.equals(1);
          check(api.clones).equals(0);
          check(c.read(activeConversationProvider)!.id).equals('c1');
        }
        check(await db.chatsDao.allServerChatReconcileEntries()).length
            .equals(1);
      },
    );

    test(
      'sends nothing offline, without import rights, or for a shared chat',
      () async {
        await seed();
        final stored = await _loaded(db, 'c1');
        final cases = <ChatBranchFailure, ProviderContainer>{
          ChatBranchFailure.offline: container(
            active: stored,
            online: false,
            permissions: allowed,
          ),
          ChatBranchFailure.forkForbidden: container(
            active: stored,
            permissions: () async => {
              'chat': <String, dynamic>{'import': false},
            },
          ),
          ChatBranchFailure.unavailable: container(
            active: stored.copyWith(userId: 'someone-else'),
            permissions: allowed,
          ),
        };

        for (final entry in cases.entries) {
          await check(
            forkChatAtMessage(
              entry.value,
              conversation: entry.value.read(activeConversationProvider)!,
              messageId: 'a1',
            ),
          ).throws<ChatBranchException>(
            (e) => e.has((it) => it.reason, 'reason').equals(entry.key),
          );
        }
        check(api.forks).isEmpty();
        check(api.clones).equals(0);
      },
    );

    test('an unknown message is never sent', () async {
      await seed();
      final c = container(
        active: await _loaded(db, 'c1'),
        permissions: allowed,
      );

      await check(
        forkChatAtMessage(
          c,
          conversation: c.read(activeConversationProvider)!,
          messageId: 'ghost',
        ),
      ).throws<ChatBranchException>(
        (e) => e
            .has((it) => it.reason, 'reason')
            .equals(ChatBranchFailure.messageNotFound),
      );
      check(api.forks).isEmpty();
    });
  });
}
