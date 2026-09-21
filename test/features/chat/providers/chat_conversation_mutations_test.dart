/// Characterization tests for the conversation-mutation block of
/// `lib/features/chat/providers/chat_providers.dart`:
/// `renameDirectLocalConversation`, `deleteDirectLocalConversation`,
/// `pinConversation`, `archiveConversation`, `shareConversation`,
/// `deleteSharedConversation` and `cloneConversation`.
///
/// These tests pin CURRENT OBSERVED behaviour so the block can be moved
/// verbatim into a `part` file and proven unchanged. Nothing here asserts
/// what the code *should* do; where behaviour looks wrong it is pinned with a
/// `BUG-SHAPED` comment instead of being fixed.
///
/// Not covered here: the block's private helpers `_saveConversationLocally`
/// and `_generateConversationTitle`. Both are private and their only call
/// sites are the reviewer-mode branches buried inside `sendMessage` and
/// `regenerateMessage`, which first demand a selected model, a direct-route
/// resolution, mutation/completion ownership tokens and a word-by-word
/// simulated stream. Reaching them would test that scaffolding rather than
/// the helpers, and `_generateConversationTitle` is unreachable from either
/// site (both require a non-null active conversation, which is exactly the
/// case where the title is never generated).
///
/// The harness deliberately uses the real `conversationsProvider`, real Drift
/// databases (one Open WebUI store, one direct-local store) and the real
/// per-chat `ChatLocks`, so the assertions cover the database writes as well
/// as the in-memory projections. Only the sync engine and `ApiService` are
/// faked. The mutators take a `WidgetRef` (a sealed Riverpod type), so each
/// test captures one from a `Consumer` and then runs its real-async work
/// inside `tester.runAsync`.
library;

import 'dart:async';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/openwebui_storage_test_overrides.dart';

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _RecordingSyncEngine extends SyncEngine {
  _RecordingSyncEngine(this.pulls);

  final List<String> pulls;

  @override
  Future<PullResult?> requestPull({required String reason}) {
    pulls.add(reason);
    return Future<PullResult?>.value(null);
  }
}

final class _ApiState extends Notifier<ApiService?> {
  _ApiState(this.initial);

  final ApiService? initial;

  @override
  ApiService? build() => initial;

  void set(ApiService? service) => state = service;
}

typedef _ToggleCall = ({String id, bool value});

/// Records every conversation mutation the block sends to Open WebUI and can
/// be told to fail or to block mid-flight.
final class _MutationApi extends ApiService {
  _MutationApi({this.label = 'api'})
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  final String label;
  final List<_ToggleCall> pinCalls = <_ToggleCall>[];
  final List<_ToggleCall> archiveCalls = <_ToggleCall>[];
  final List<String> shareCalls = <String>[];
  final List<String> deleteShareCalls = <String>[];
  final List<String> cloneCalls = <String>[];

  /// Thrown by the next call when set.
  Object? failure;

  /// Completed by the test to release an in-flight call. Tests must build
  /// this (and [callStarted]) inside `tester.runAsync`: a completer created
  /// in the surrounding fake-async zone delivers its continuations through
  /// the fake microtask queue, which never drains while `runAsync` is on the
  /// real event loop.
  Completer<void>? gate;

  /// Completes as soon as a gated call has started.
  Completer<void>? callStarted;

  String? shareIdResult = 'share-1';
  Conversation? cloneResult;

  Future<void> _admit() async {
    final started = callStarted;
    if (started != null && !started.isCompleted) started.complete();
    final pending = gate;
    if (pending != null) await pending.future;
    final thrown = failure;
    if (thrown != null) throw thrown;
  }

  @override
  Future<void> pinConversation(String id, bool pinned) async {
    pinCalls.add((id: id, value: pinned));
    await _admit();
  }

  @override
  Future<void> archiveConversation(String id, bool archived) async {
    archiveCalls.add((id: id, value: archived));
    await _admit();
  }

  @override
  Future<String?> shareConversation(String id) async {
    shareCalls.add(id);
    await _admit();
    return shareIdResult;
  }

  @override
  Future<void> deleteSharedConversation(String id) async {
    deleteShareCalls.add(id);
    await _admit();
  }

  @override
  Future<Conversation> cloneConversation(String id) async {
    cloneCalls.add(id);
    await _admit();
    final clone = cloneResult;
    if (clone == null) throw StateError('no clone configured');
    return clone;
  }
}

ChatRows _rows(
  String id, {
  required String title,
  required int updatedAt,
  bool pinned = false,
  bool archived = false,
}) {
  return ChatBlobMapper.blobToRows(
    chatId: id,
    blob: {
      'title': title,
      'history': {
        'currentId': '$id-m1',
        'messages': {
          '$id-m1': {
            'id': '$id-m1',
            'parentId': null,
            'childrenIds': <String>[],
            'role': 'user',
            'content': 'hello from $id',
            'timestamp': updatedAt,
          },
        },
      },
    },
    title: title,
    pinned: pinned,
    archived: archived,
    createdAt: updatedAt,
    updatedAt: updatedAt,
  );
}

String _directScoped(String rawId) => ChatStorageIdentity(
  rawId: rawId,
  storage: ChatStorageKind.directLocal,
).scopedId;

String _openWebUiScoped(String rawId) => ChatStorageIdentity(
  rawId: rawId,
  storage: ChatStorageKind.openWebUi,
).scopedId;

Conversation _conversation(
  String id, {
  String title = 'Title',
  ChatStorageKind? storage,
  bool pinned = false,
  bool archived = false,
  String? shareId,
  String? folderId,
  List<ChatMessage> messages = const <ChatMessage>[],
}) {
  final now = DateTime.utc(2026, 3, 1);
  final conversation = Conversation(
    id: id,
    title: title,
    createdAt: now,
    updatedAt: now,
    pinned: pinned,
    archived: archived,
    shareId: shareId,
    folderId: folderId,
    messages: messages,
  );
  return storage == null
      ? conversation
      : withChatStorageProvenance(conversation, storage);
}

ChatMessage _message(String id, String content) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  timestamp: DateTime.utc(2026, 3, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase serverDb;
  late AppDatabase directDb;
  late bool previousDontWarnAboutMultipleDatabases;

  setUpAll(() {
    previousDontWarnAboutMultipleDatabases =
        driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases =
        previousDontWarnAboutMultipleDatabases;
  });

  setUp(() {
    serverDb = AppDatabase(NativeDatabase.memory());
    directDb = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await serverDb.close();
    await directDb.close();
  });

  ProviderContainer containerWith({
    required List<String> pulls,
    Override? apiOverride,
  }) {
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: serverDb),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        socketServiceProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(() => _RecordingSyncEngine(pulls)),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
        apiOverride ?? apiServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<WidgetRef> captureRef(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, child) {
            captured = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  Future<void> seedDirect(
    String id, {
    required String title,
    int updatedAt = 100,
    bool pinned = false,
    bool archived = false,
  }) {
    return directDb.chatsDao.upsertLocalOnlyChat(
      rows: _rows(
        id,
        title: title,
        updatedAt: updatedAt,
        pinned: pinned,
        archived: archived,
      ),
    );
  }

  Future<void> seedServer(
    String id, {
    required String title,
    int updatedAt = 100,
    bool pinned = false,
    bool archived = false,
  }) {
    return serverDb.chatsDao.upsertServerChat(
      rows: _rows(
        id,
        title: title,
        updatedAt: updatedAt,
        pinned: pinned,
        archived: archived,
      ),
    );
  }

  List<Conversation> listed(ProviderContainer container) =>
      container.read(conversationsProvider).requireValue;

  Conversation listedFor(ProviderContainer container, String scopedId) =>
      listed(container).firstWhere(
        (conversation) => conversationMatchesScopedId(conversation, scopedId),
      );

  Future<void> waitUntil(
    FutureOr<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!(await condition())) {
      if (DateTime.now().isAfter(deadline)) fail('waitUntil timed out');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  group('renameDirectLocalConversation', () {
    testWidgets('writes the row, the list entry and the active chat', (
      tester,
    ) async {
      final pulls = <String>[];
      final container = containerWith(pulls: pulls);
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedDirect('chat-a', title: 'Old title');
        final projection = await container.read(conversationsProvider.future);
        expect(projection.single.title, 'Old title');
        expect(isDirectLocalConversation(projection.single), isTrue);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation(
                'chat-a',
                title: 'Old title',
                storage: ChatStorageKind.directLocal,
              ),
            );

        await renameDirectLocalConversation(
          ref,
          _directScoped('chat-a'),
          'New title',
        );

        final row = await directDb.chatsDao.getChat('chat-a');
        expect(row!.title, 'New title');
        // The device clock advances the row's updatedAt (epoch seconds).
        expect(row.updatedAt, greaterThan(100));
        // Local-only envelope writes never dirty the row or enqueue sync work.
        expect(row.dirty, isFalse);
        expect(await directDb.outboxDao.pendingForChat('chat-a'), isEmpty);
        expect(listed(container).single.title, 'New title');
        expect(container.read(activeConversationProvider)!.title, 'New title');
        // The direct-local branch never asks the sync engine for a pull.
        expect(pulls, isEmpty);
      });
    });

    testWidgets('rejects a selection scoped to Open WebUI storage', (
      tester,
    ) async {
      final container = containerWith(pulls: <String>[]);
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedDirect('chat-a', title: 'Old title');
        await container.read(conversationsProvider.future);

        await expectLater(
          renameDirectLocalConversation(
            ref,
            _openWebUiScoped('chat-a'),
            'Never applied',
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'The selected chat is not stored on this device.',
            ),
          ),
        );

        final row = await directDb.chatsDao.getChat('chat-a');
        expect(row!.title, 'Old title');
      });
    });

    testWidgets('an unscoped id is promoted to the direct-local store only', (
      tester,
    ) async {
      final container = containerWith(pulls: <String>[]);
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        // Same raw id in both stores: the promotion must not reach the server
        // row or the Open WebUI active chat.
        await seedDirect('collision', title: 'Direct old', updatedAt: 200);
        await seedServer('collision', title: 'Server old', updatedAt: 100);
        await container.read(conversationsProvider.future);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation(
                'collision',
                title: 'Server old',
                storage: ChatStorageKind.openWebUi,
              ),
            );

        await renameDirectLocalConversation(ref, 'collision', 'Direct new');

        expect(
          (await directDb.chatsDao.getChat('collision'))!.title,
          'Direct new',
        );
        expect(
          (await serverDb.chatsDao.getChat('collision'))!.title,
          'Server old',
        );
        expect(
          listedFor(container, _directScoped('collision')).title,
          'Direct new',
        );
        expect(
          listedFor(container, _openWebUiScoped('collision')).title,
          'Server old',
        );
        expect(container.read(activeConversationProvider)!.title, 'Server old');
      });
    });
  });

  group('deleteDirectLocalConversation', () {
    testWidgets('drops the on-device row and leaves a colliding server row', (
      tester,
    ) async {
      final container = containerWith(pulls: <String>[]);
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedDirect('collision', title: 'Direct', updatedAt: 200);
        await seedServer('collision', title: 'Server', updatedAt: 100);
        expect(
          await container.read(conversationsProvider.future),
          hasLength(2),
        );

        await deleteDirectLocalConversation(ref, _directScoped('collision'));

        expect(await directDb.chatsDao.getChat('collision'), isNull);
        expect((await serverDb.chatsDao.getChat('collision'))!.title, 'Server');
        final remaining = listed(container);
        expect(remaining, hasLength(1));
        expect(isDirectLocalConversation(remaining.single), isFalse);
      });
    });

    testWidgets('rejects a selection scoped to Open WebUI storage', (
      tester,
    ) async {
      final container = containerWith(pulls: <String>[]);
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedDirect('chat-a', title: 'Direct');
        await container.read(conversationsProvider.future);

        await expectLater(
          deleteDirectLocalConversation(ref, _openWebUiScoped('chat-a')),
          throwsA(isA<StateError>()),
        );

        expect(await directDb.chatsDao.getChat('chat-a'), isNotNull);
        expect(listed(container), hasLength(1));
      });
    });

    testWidgets('deleting the open chat leaves it selected and rendered', (
      tester,
    ) async {
      // Pinned as-is: unlike archiveConversation, the delete mutator never
      // clears activeConversationProvider or the transcript, so the deleted
      // chat stays on screen until the caller navigates away.
      final container = containerWith(pulls: <String>[]);
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedDirect('chat-a', title: 'Direct');
        await container.read(conversationsProvider.future);
        final active = _conversation(
          'chat-a',
          title: 'Direct',
          storage: ChatStorageKind.directLocal,
          messages: [_message('m1', 'hello')],
        );
        container.read(activeConversationProvider.notifier).set(active);
        container
            .read(chatMessagesProvider.notifier)
            .setMessages(active.messages);

        await deleteDirectLocalConversation(ref, _directScoped('chat-a'));

        expect(await directDb.chatsDao.getChat('chat-a'), isNull);
        expect(listed(container), isEmpty);
        expect(container.read(activeConversationProvider)!.id, 'chat-a');
        expect(container.read(chatMessagesProvider), isNotEmpty);
      });
    });
  });

  group('pinConversation', () {
    testWidgets('pins an on-device chat locally and never calls the API', (
      tester,
    ) async {
      final pulls = <String>[];
      final api = _MutationApi();
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedDirect('chat-a', title: 'Direct');
        await container.read(conversationsProvider.future);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation(
                'chat-a',
                title: 'Direct',
                storage: ChatStorageKind.directLocal,
              ),
            );

        await pinConversation(ref, _directScoped('chat-a'), true);

        expect((await directDb.chatsDao.getChat('chat-a'))!.pinned, isTrue);
        expect(await directDb.outboxDao.pendingForChat('chat-a'), isEmpty);
        expect(listed(container).single.pinned, isTrue);
        expect(container.read(activeConversationProvider)!.pinned, isTrue);
        expect(api.pinCalls, isEmpty);
        // The direct-local branch returns before refreshConversationsCache.
        expect(pulls, isEmpty);
      });
    });

    testWidgets('an unscoped id still takes the local branch when the only '
        'listed row is on-device', (tester) async {
      final api = _MutationApi();
      final container = containerWith(
        pulls: <String>[],
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedDirect('chat-a', title: 'Direct');
        await container.read(conversationsProvider.future);

        // Storage is inferred from the listed conversation, not the id.
        await pinConversation(ref, 'chat-a', true);

        expect((await directDb.chatsDao.getChat('chat-a'))!.pinned, isTrue);
        expect(listed(container).single.pinned, isTrue);
        expect(api.pinCalls, isEmpty);
      });
    });

    testWidgets('pins an Open WebUI chat through the API with the raw id', (
      tester,
    ) async {
      final pulls = <String>[];
      final api = _MutationApi();
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation(
                'chat-s',
                title: 'Server',
                storage: ChatStorageKind.openWebUi,
              ),
            );

        await pinConversation(ref, _openWebUiScoped('chat-s'), true);

        // The scoped selection is decoded before it reaches the network.
        expect(api.pinCalls, [(id: 'chat-s', value: true)]);
        expect(listed(container).single.pinned, isTrue);
        expect(container.read(activeConversationProvider)!.pinned, isTrue);
        expect(pulls, ['cache-refresh']);
        // updateConversationFromRemote also persists the envelope change.
        await waitUntil(
          () async => (await serverDb.chatsDao.getChat('chat-s'))!.pinned,
        );
      });
    });

    testWidgets('a failing API pin rethrows and leaves every projection '
        'untouched', (tester) async {
      final pulls = <String>[];
      final api = _MutationApi()..failure = Exception('pin failed');
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation(
                'chat-s',
                title: 'Server',
                storage: ChatStorageKind.openWebUi,
              ),
            );

        await expectLater(
          pinConversation(ref, _openWebUiScoped('chat-s'), true),
          throwsA(isA<Exception>()),
        );

        // Pin has no optimistic write, so a failure needs no rollback.
        expect(listed(container).single.pinned, isFalse);
        expect(container.read(activeConversationProvider)!.pinned, isFalse);
        expect((await serverDb.chatsDao.getChat('chat-s'))!.pinned, isFalse);
        expect(pulls, isEmpty);
      });
    });

    testWidgets('throws when no API service is available', (tester) async {
      final container = containerWith(pulls: <String>[]);
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);

        await expectLater(
          pinConversation(ref, _openWebUiScoped('chat-s'), true),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('No API service available'),
            ),
          ),
        );
        expect(listed(container).single.pinned, isFalse);
      });
    });
  });

  group('archiveConversation', () {
    testWidgets('archiving an on-device chat clears the active selection, '
        'its messages and the selected filters', (tester) async {
      final pulls = <String>[];
      final api = _MutationApi();
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedDirect('chat-a', title: 'Direct');
        await container.read(conversationsProvider.future);
        final active = _conversation(
          'chat-a',
          title: 'Direct',
          storage: ChatStorageKind.directLocal,
          messages: [_message('m1', 'hello')],
        );
        container.read(activeConversationProvider.notifier).set(active);
        container
            .read(chatMessagesProvider.notifier)
            .setMessages(active.messages);
        container.read(selectedFilterIdsProvider.notifier).set(['filter-a']);
        expect(container.read(chatMessagesProvider), isNotEmpty);

        await archiveConversation(ref, _directScoped('chat-a'), true);

        expect((await directDb.chatsDao.getChat('chat-a'))!.archived, isTrue);
        expect(listed(container).single.archived, isTrue);
        expect(container.read(activeConversationProvider), isNull);
        expect(container.read(chatMessagesProvider), isEmpty);
        expect(container.read(selectedFilterIdsProvider), isEmpty);
        expect(api.archiveCalls, isEmpty);
        expect(pulls, isEmpty);
      });
    });

    testWidgets('unarchiving an on-device chat keeps the active selection', (
      tester,
    ) async {
      final container = containerWith(pulls: <String>[]);
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedDirect('chat-a', title: 'Direct', archived: true);
        await container.read(conversationsProvider.future);
        final active = _conversation(
          'chat-a',
          title: 'Direct',
          storage: ChatStorageKind.directLocal,
          archived: true,
          messages: [_message('m1', 'hello')],
        );
        container.read(activeConversationProvider.notifier).set(active);
        container
            .read(chatMessagesProvider.notifier)
            .setMessages(active.messages);
        container.read(selectedFilterIdsProvider.notifier).set(['filter-a']);

        await archiveConversation(ref, _directScoped('chat-a'), false);

        expect((await directDb.chatsDao.getChat('chat-a'))!.archived, isFalse);
        expect(container.read(activeConversationProvider)!.archived, isFalse);
        expect(container.read(chatMessagesProvider), isNotEmpty);
        // Filters are only cleared when the conversation is left behind.
        expect(container.read(selectedFilterIdsProvider), ['filter-a']);
      });
    });

    testWidgets('an Open WebUI archive clears the active chat before the '
        'request and refreshes afterwards', (tester) async {
      final pulls = <String>[];
      final api = _MutationApi();
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);
        final active = _conversation(
          'chat-s',
          title: 'Server',
          storage: ChatStorageKind.openWebUi,
          messages: [_message('m1', 'hello')],
        );
        container.read(activeConversationProvider.notifier).set(active);
        container
            .read(chatMessagesProvider.notifier)
            .setMessages(active.messages);
        container.read(selectedFilterIdsProvider.notifier).set(['filter-a']);
        api
          ..gate = Completer<void>()
          ..callStarted = Completer<void>();

        final pending = archiveConversation(
          ref,
          _openWebUiScoped('chat-s'),
          true,
        );
        await api.callStarted!.future.timeout(const Duration(seconds: 2));

        // The optimistic clear lands before the server confirms.
        expect(container.read(activeConversationProvider), isNull);
        expect(container.read(chatMessagesProvider), isEmpty);
        expect(container.read(selectedFilterIdsProvider), isEmpty);
        expect(listed(container).single.archived, isFalse);

        api.gate!.complete();
        await pending;

        expect(api.archiveCalls, [(id: 'chat-s', value: true)]);
        expect(listed(container).single.archived, isTrue);
        expect(pulls, ['cache-refresh']);
      });
    });

    testWidgets('a failing Open WebUI archive restores the active chat and '
        'the previous filters', (tester) async {
      final pulls = <String>[];
      final api = _MutationApi()..failure = Exception('archive failed');
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);
        final active = _conversation(
          'chat-s',
          title: 'Server',
          storage: ChatStorageKind.openWebUi,
          messages: [_message('m1', 'hello')],
        );
        container.read(activeConversationProvider.notifier).set(active);
        container
            .read(chatMessagesProvider.notifier)
            .setMessages(active.messages);
        container.read(selectedFilterIdsProvider.notifier).set(['filter-a']);

        await expectLater(
          archiveConversation(ref, _openWebUiScoped('chat-s'), true),
          throwsA(isA<Exception>()),
        );

        expect(container.read(activeConversationProvider)!.id, 'chat-s');
        expect(container.read(selectedFilterIdsProvider), ['filter-a']);
        expect(listed(container).single.archived, isFalse);
        expect(pulls, isEmpty);
        // Restoring the selection also re-projects its transcript, which is
        // what the source comment means by "restored through the listener".
        expect(container.read(chatMessagesProvider).single.content, 'hello');
      });
    });
  });

  group('shareConversation', () {
    testWidgets('stores the returned share id on the list row and the active '
        'chat', (tester) async {
      final pulls = <String>[];
      final api = _MutationApi()..shareIdResult = 'share-abc';
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation(
                'chat-s',
                title: 'Server',
                storage: ChatStorageKind.openWebUi,
              ),
            );

        final shareId = await shareConversation(
          ref,
          _openWebUiScoped('chat-s'),
        );

        expect(shareId, 'share-abc');
        expect(api.shareCalls, ['chat-s']);
        // Optimistic only: the chat-list projection has no share_id column, so
        // this value does not survive the next database emission.
        expect(listed(container).single.shareId, 'share-abc');
        expect(
          container.read(activeConversationProvider)!.shareId,
          'share-abc',
        );
        expect(pulls, ['cache-refresh']);
      });
    });

    testWidgets('an API service swapped mid-flight still returns the share id '
        'but skips every state update', (tester) async {
      final pulls = <String>[];
      final first = _MutationApi(label: 'first')..shareIdResult = 'share-first';
      final second = _MutationApi(label: 'second');
      final apiState = NotifierProvider<_ApiState, ApiService?>(
        () => _ApiState(first),
      );
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWith(
          (ref) => ref.watch(apiState),
        ),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation(
                'chat-s',
                title: 'Server',
                storage: ChatStorageKind.openWebUi,
              ),
            );

        first
          ..gate = Completer<void>()
          ..callStarted = Completer<void>();

        final pending = shareConversation(ref, _openWebUiScoped('chat-s'));
        await first.callStarted!.future.timeout(const Duration(seconds: 2));
        container.read(apiState.notifier).set(second);
        first.gate!.complete();

        expect(await pending, 'share-first');
        expect(listed(container).single.shareId, isNull);
        expect(container.read(activeConversationProvider)!.shareId, isNull);
        expect(pulls, isEmpty);
      });
    });

    testWidgets('an unscoped id stamps the share id onto a colliding '
        'on-device active chat', (tester) async {
      // BUG-SHAPED: shareConversation matches the active chat with
      // conversationMatchesScopedId instead of the storage-aware
      // _activeConversationMatchesSelection used by pin/archive. An unscoped
      // id therefore matches a direct-local active chat, so an on-device
      // conversation that was never shared ends up carrying the server's
      // share id, while the list update lands on the Open WebUI row.
      final api = _MutationApi()..shareIdResult = 'share-xyz';
      final container = containerWith(
        pulls: <String>[],
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedDirect('collision', title: 'Direct', updatedAt: 200);
        await seedServer('collision', title: 'Server', updatedAt: 100);
        await container.read(conversationsProvider.future);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation(
                'collision',
                title: 'Direct',
                storage: ChatStorageKind.directLocal,
              ),
            );

        final shareId = await shareConversation(ref, 'collision');

        expect(shareId, 'share-xyz');
        expect(api.shareCalls, ['collision']);
        final active = container.read(activeConversationProvider)!;
        expect(isDirectLocalConversation(active), isTrue);
        expect(active.shareId, 'share-xyz');
        expect(
          listedFor(container, _openWebUiScoped('collision')).shareId,
          'share-xyz',
        );
        expect(
          listedFor(container, _directScoped('collision')).shareId,
          isNull,
        );
      });
    });

    testWidgets('rethrows and leaves the share id unset when the API fails', (
      tester,
    ) async {
      final pulls = <String>[];
      final api = _MutationApi()..failure = Exception('share failed');
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);

        await expectLater(
          shareConversation(ref, _openWebUiScoped('chat-s')),
          throwsA(isA<Exception>()),
        );

        expect(listed(container).single.shareId, isNull);
        expect(pulls, isEmpty);
      });
    });
  });

  group('deleteSharedConversation', () {
    testWidgets('clears the share id from the list row and the active chat', (
      tester,
    ) async {
      final pulls = <String>[];
      final api = _MutationApi();
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation(
                'chat-s',
                title: 'Server',
                storage: ChatStorageKind.openWebUi,
                shareId: 'share-abc',
              ),
            );
        // The narrow chat-list projection has no share_id column, so the list
        // row never carries one to begin with; only the active chat does.
        expect(listed(container).single.shareId, isNull);

        await deleteSharedConversation(ref, _openWebUiScoped('chat-s'));

        expect(api.deleteShareCalls, ['chat-s']);
        expect(listed(container).single.shareId, isNull);
        expect(container.read(activeConversationProvider)!.shareId, isNull);
        expect(pulls, ['cache-refresh']);
      });
    });

    testWidgets('rethrows and keeps the share id when the API fails', (
      tester,
    ) async {
      final pulls = <String>[];
      final api = _MutationApi()..failure = Exception('unshare failed');
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation(
                'chat-s',
                title: 'Server',
                storage: ChatStorageKind.openWebUi,
                shareId: 'share-abc',
              ),
            );

        await expectLater(
          deleteSharedConversation(ref, _openWebUiScoped('chat-s')),
          throwsA(isA<Exception>()),
        );

        expect(
          container.read(activeConversationProvider)!.shareId,
          'share-abc',
        );
        expect(pulls, isEmpty);
      });
    });
  });

  group('cloneConversation', () {
    testWidgets('selects the clone, adds it to the list and refreshes', (
      tester,
    ) async {
      final pulls = <String>[];
      final api = _MutationApi()
        ..cloneResult = _conversation('chat-clone', title: 'Copy of Server');
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);
        container.read(selectedFilterIdsProvider.notifier).set(['filter-a']);

        await cloneConversation(ref, 'chat-s');

        expect(api.cloneCalls, ['chat-s']);
        expect(container.read(activeConversationProvider)!.id, 'chat-clone');
        expect(container.read(selectedFilterIdsProvider), isEmpty);
        expect(
          listed(container).map((conversation) => conversation.id),
          containsAll(<String>['chat-s', 'chat-clone']),
        );
        expect(pulls, ['cache-refresh']);
        // upsertConversation also materializes the clone's envelope row.
        await waitUntil(
          () async => await serverDb.chatsDao.getChat('chat-clone') != null,
        );
      });
    });

    testWidgets('sends the selection id to the API verbatim', (tester) async {
      // BUG-SHAPED: every sibling mutator decodes ChatStorageIdentity first,
      // but cloneConversation forwards its argument unchanged. A scoped
      // selection (what the chat list hands out) reaches the network as the
      // internal transport string rather than the chat id.
      final api = _MutationApi()
        ..cloneResult = _conversation('chat-clone', title: 'Copy');
      final container = containerWith(
        pulls: <String>[],
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);

        await cloneConversation(ref, _openWebUiScoped('chat-s'));

        expect(api.cloneCalls.single, _openWebUiScoped('chat-s'));
        expect(api.cloneCalls.single, isNot('chat-s'));
        expect(api.cloneCalls.single, startsWith('conduit-chat://scoped/'));
      });
    });

    testWidgets('rethrows and leaves the selection untouched when the API '
        'fails', (tester) async {
      final pulls = <String>[];
      final api = _MutationApi()..failure = Exception('clone failed');
      final container = containerWith(
        pulls: pulls,
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      final ref = await captureRef(tester, container);

      await tester.runAsync(() async {
        await seedServer('chat-s', title: 'Server');
        await container.read(conversationsProvider.future);
        final active = _conversation(
          'chat-s',
          title: 'Server',
          storage: ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(active);
        container.read(selectedFilterIdsProvider.notifier).set(['filter-a']);

        await expectLater(
          cloneConversation(ref, 'chat-s'),
          throwsA(isA<Exception>()),
        );

        expect(container.read(activeConversationProvider)!.id, 'chat-s');
        // The conversation-boundary reset only runs after a successful clone.
        expect(container.read(selectedFilterIdsProvider), ['filter-a']);
        expect(listed(container), hasLength(1));
        expect(pulls, isEmpty);
      });
    });
  });
}
