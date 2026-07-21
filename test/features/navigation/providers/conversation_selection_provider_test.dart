import 'dart:async';

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/app_startup_providers.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

const _server = ServerConfig(
  id: 'selection-test-server',
  name: 'Selection Test Server',
  url: 'https://example.com',
);

const _otherServer = ServerConfig(
  id: 'selection-test-server-other',
  name: 'Other Selection Test Server',
  url: 'https://other.example.com',
);

final _serverOwnerProvider =
    NotifierProvider<_ServerOwnerNotifier, ServerConfig?>(
      _ServerOwnerNotifier.new,
    );

final class _ServerOwnerNotifier extends Notifier<ServerConfig?> {
  @override
  ServerConfig? build() => _server;

  void set(ServerConfig? server) => state = server;
}

final _authOwnerProvider = NotifierProvider<_AuthOwnerNotifier, _AuthOwner>(
  _AuthOwnerNotifier.new,
);

final class _AuthOwner {
  const _AuthOwner({required this.token, required this.epoch});

  final String? token;
  final Object epoch;
}

final class _AuthOwnerNotifier extends Notifier<_AuthOwner> {
  @override
  _AuthOwner build() => _AuthOwner(token: 'token-a', epoch: Object());

  void setToken(String? token) {
    state = _AuthOwner(token: token, epoch: Object());
  }
}

final class _NoopAccountStorageIsolation
    extends OpenWebUiAccountStorageIsolation {
  @override
  void build() {}
}

final class _PendingAccountStorageIsolation
    extends OpenWebUiAccountStorageIsolation {
  _PendingAccountStorageIsolation(this.gate);

  final Future<void> gate;

  @override
  void build() {}

  @override
  Future<void> get settled => gate;
}

final class _SeededActiveConversation extends ActiveConversationNotifier {
  _SeededActiveConversation(this.initialConversation);

  final Conversation initialConversation;

  @override
  Conversation? build() => initialConversation;
}

Future<void> _flushMicrotasks([int count = 3]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Conversation _conversation(
  String id, {
  required ChatStorageKind storage,
  String? body,
}) {
  final timestamp = DateTime(2026, 1, 1);
  return withChatStorageProvenance(
    Conversation(
      id: id,
      title: id,
      createdAt: timestamp,
      updatedAt: timestamp,
      messages: body == null
          ? const <ChatMessage>[]
          : <ChatMessage>[
              ChatMessage(
                id: '$id-message',
                role: 'assistant',
                content: body,
                timestamp: timestamp,
              ),
            ],
    ),
    storage,
  );
}

Future<ProviderContainer> _createContainer({
  Conversation? activeConversation,
  Override? isolationOverride,
  Duration timeout = const Duration(milliseconds: 250),
  List<Override> extraOverrides = const <Override>[],
}) async {
  final database = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWithValue(const AppSettings()),
      isAuthenticatedProvider2.overrideWith(
        (ref) => ref.watch(_authOwnerProvider).token != null,
      ),
      authTokenProvider3.overrideWith(
        (ref) => ref.watch(_authOwnerProvider).token,
      ),
      currentUserProvider2.overrideWithValue(null),
      openWebUiAuthSessionEpochProvider.overrideWith(
        (ref) => ref.watch(_authOwnerProvider).epoch,
      ),
      activeServerProvider.overrideWith(
        (ref) async => ref.watch(_serverOwnerProvider),
      ),
      apiServiceProvider.overrideWithValue(null),
      appDatabaseProvider.overrideWithValue(database),
      isolationOverride ??
          openWebUiAccountStorageIsolationProvider.overrideWith(
            _NoopAccountStorageIsolation.new,
          ),
      conversationSelectionTimeoutProvider.overrideWithValue(timeout),
      if (activeConversation != null)
        activeConversationProvider.overrideWith(
          () => _SeededActiveConversation(activeConversation),
        ),
      ...extraOverrides,
    ],
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  await container.read(activeServerProvider.future);
  return container;
}

void _certifyOpenWebUiStorage(ProviderContainer container) {
  container
      .read(openWebUiCertifiedDatabaseServerProvider.notifier)
      .set(_server.id);
  container.read(openWebUiDatabaseAccessProvider.notifier).open();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'transient OpenWebUI certification resumes pending selection and commits',
    () async {
      final previous = _conversation(
        'previous',
        storage: ChatStorageKind.directLocal,
        body: 'Previous body',
      );
      final summary = _conversation(
        'server-chat',
        storage: ChatStorageKind.openWebUi,
      );
      final full = _conversation(
        'server-chat',
        storage: ChatStorageKind.openWebUi,
        body: 'Loaded after certification',
      );
      var loadCalls = 0;
      final scopedId = conversationScopedId(summary);
      final container = await _createContainer(
        activeConversation: previous,
        extraOverrides: [
          loadConversationProvider(scopedId).overrideWith((ref) async {
            loadCalls += 1;
            return full;
          }),
        ],
      );

      final selection = container
          .read(conversationSelectionProvider.notifier)
          .select(summary);
      await _flushMicrotasks();

      final pending = container.read(conversationSelectionProvider);
      expect(pending.isLoading, isTrue);
      expect(pending.pendingConversationId, scopedId);
      expect(container.read(activeConversationProvider)?.id, previous.id);
      expect(loadCalls, 0);

      _certifyOpenWebUiStorage(container);
      final result = await selection;

      expect(result.disposition, ConversationSelectionDisposition.committed);
      expect(loadCalls, 1);
      expect(container.read(activeConversationProvider)?.id, full.id);
      expect(
        container.read(activeConversationProvider)?.messages.single.content,
        'Loaded after certification',
      );
      expect(container.read(conversationSelectionProvider).isLoading, isFalse);
    },
  );

  test(
    'superseding during initial isolation cancels the first wait promptly',
    () async {
      final isolationGate = Completer<void>();
      final first = _conversation(
        'waiting-for-isolation',
        storage: ChatStorageKind.openWebUi,
      );
      final second = _conversation(
        'replacement',
        storage: ChatStorageKind.directLocal,
      );
      final secondFull = _conversation(
        'replacement',
        storage: ChatStorageKind.directLocal,
        body: 'Replacement body',
      );
      final container = await _createContainer(
        isolationOverride: openWebUiAccountStorageIsolationProvider
            .overrideWith(
              () => _PendingAccountStorageIsolation(isolationGate.future),
            ),
        extraOverrides: [
          loadConversationProvider(
            conversationScopedId(second),
          ).overrideWith((ref) async => secondFull),
        ],
      );

      final firstSelection = container
          .read(conversationSelectionProvider.notifier)
          .select(first);
      await _flushMicrotasks();
      final secondResult = await container
          .read(conversationSelectionProvider.notifier)
          .select(second);
      final firstResult = await firstSelection.timeout(
        const Duration(milliseconds: 100),
      );

      expect(
        secondResult.disposition,
        ConversationSelectionDisposition.committed,
      );
      expect(
        firstResult.disposition,
        ConversationSelectionDisposition.canceled,
      );
      expect(isolationGate.isCompleted, isFalse);
      expect(container.read(activeConversationProvider)?.id, second.id);
    },
  );

  test(
    'superseding during readiness cancels the first wait promptly',
    () async {
      final first = _conversation(
        'waiting-for-readiness',
        storage: ChatStorageKind.openWebUi,
      );
      final second = _conversation(
        'replacement',
        storage: ChatStorageKind.directLocal,
      );
      final secondFull = _conversation(
        'replacement',
        storage: ChatStorageKind.directLocal,
        body: 'Replacement body',
      );
      final container = await _createContainer(
        extraOverrides: [
          loadConversationProvider(
            conversationScopedId(second),
          ).overrideWith((ref) async => secondFull),
        ],
      );

      final firstSelection = container
          .read(conversationSelectionProvider.notifier)
          .select(first);
      await _flushMicrotasks();
      expect(container.read(conversationSelectionProvider).isLoading, isTrue);

      final secondResult = await container
          .read(conversationSelectionProvider.notifier)
          .select(second);
      final firstResult = await firstSelection.timeout(
        const Duration(milliseconds: 100),
      );

      expect(
        secondResult.disposition,
        ConversationSelectionDisposition.committed,
      );
      expect(
        firstResult.disposition,
        ConversationSelectionDisposition.canceled,
      );
      expect(container.read(activeConversationProvider)?.id, second.id);
    },
  );

  test('latest selection wins when an earlier load completes last', () async {
    final first = _conversation('first', storage: ChatStorageKind.directLocal);
    final second = _conversation(
      'second',
      storage: ChatStorageKind.directLocal,
    );
    final firstGate = Completer<Conversation>();
    final secondGate = Completer<Conversation>();
    final container = await _createContainer(
      extraOverrides: [
        loadConversationProvider(
          conversationScopedId(first),
        ).overrideWith((ref) => firstGate.future),
        loadConversationProvider(
          conversationScopedId(second),
        ).overrideWith((ref) => secondGate.future),
      ],
    );

    final firstSelection = container
        .read(conversationSelectionProvider.notifier)
        .select(first);
    await _flushMicrotasks();
    final secondSelection = container
        .read(conversationSelectionProvider.notifier)
        .select(second);
    await _flushMicrotasks();

    secondGate.complete(
      _conversation(
        'second',
        storage: ChatStorageKind.directLocal,
        body: 'Second body',
      ),
    );
    final secondResult = await secondSelection;
    expect(
      secondResult.disposition,
      ConversationSelectionDisposition.committed,
    );
    expect(container.read(activeConversationProvider)?.id, second.id);
    expect(container.read(conversationSelectionProvider).generation, 2);
    expect(container.read(conversationSelectionProvider).isLoading, isFalse);

    final firstResult = await firstSelection.timeout(
      const Duration(milliseconds: 100),
    );
    expect(firstResult.disposition, ConversationSelectionDisposition.canceled);

    firstGate.complete(
      _conversation(
        'first',
        storage: ChatStorageKind.directLocal,
        body: 'First body',
      ),
    );
    expect(container.read(activeConversationProvider)?.id, second.id);
    expect(container.read(conversationSelectionProvider).generation, 2);
    expect(container.read(conversationSelectionProvider).isLoading, isFalse);
  });

  test('account change cancels a pending OpenWebUI selection', () async {
    final previous = _conversation(
      'previous',
      storage: ChatStorageKind.directLocal,
      body: 'Previous body',
    );
    final summary = _conversation(
      'server-chat',
      storage: ChatStorageKind.openWebUi,
    );
    final loadGate = Completer<Conversation>();
    final scopedId = conversationScopedId(summary);
    final container = await _createContainer(
      activeConversation: previous,
      extraOverrides: [
        loadConversationProvider(
          scopedId,
        ).overrideWith((ref) => loadGate.future),
      ],
    );
    _certifyOpenWebUiStorage(container);

    final selection = container
        .read(conversationSelectionProvider.notifier)
        .select(summary);
    await _flushMicrotasks();
    container.read(_authOwnerProvider.notifier).setToken('token-b');
    loadGate.complete(
      _conversation(
        'server-chat',
        storage: ChatStorageKind.openWebUi,
        body: 'Account A private body',
      ),
    );

    final result = await selection;
    expect(result.disposition, ConversationSelectionDisposition.canceled);
    expect(container.read(activeConversationProvider)?.id, previous.id);
  });

  test('account ABA cannot revive a pending OpenWebUI selection', () async {
    final previous = _conversation(
      'previous',
      storage: ChatStorageKind.directLocal,
      body: 'Previous body',
    );
    final summary = _conversation(
      'server-chat',
      storage: ChatStorageKind.openWebUi,
    );
    final loadGate = Completer<Conversation>();
    final container = await _createContainer(
      activeConversation: previous,
      extraOverrides: [
        loadConversationProvider(
          conversationScopedId(summary),
        ).overrideWith((ref) => loadGate.future),
      ],
    );
    _certifyOpenWebUiStorage(container);

    final selection = container
        .read(conversationSelectionProvider.notifier)
        .select(summary);
    await _flushMicrotasks();
    container.read(_authOwnerProvider.notifier).setToken('token-b');
    await _flushMicrotasks();
    container.read(_authOwnerProvider.notifier).setToken('token-a');
    await _flushMicrotasks();
    loadGate.complete(
      _conversation(
        'server-chat',
        storage: ChatStorageKind.openWebUi,
        body: 'Stale account body',
      ),
    );

    final result = await selection;
    expect(result.disposition, ConversationSelectionDisposition.canceled);
    expect(container.read(activeConversationProvider)?.id, previous.id);
  });

  test('server ABA cannot revive a pending OpenWebUI selection', () async {
    final previous = _conversation(
      'previous',
      storage: ChatStorageKind.directLocal,
      body: 'Previous body',
    );
    final summary = _conversation(
      'server-chat',
      storage: ChatStorageKind.openWebUi,
    );
    final loadGate = Completer<Conversation>();
    final container = await _createContainer(
      activeConversation: previous,
      extraOverrides: [
        loadConversationProvider(
          conversationScopedId(summary),
        ).overrideWith((ref) => loadGate.future),
      ],
    );
    _certifyOpenWebUiStorage(container);

    final selection = container
        .read(conversationSelectionProvider.notifier)
        .select(summary);
    await _flushMicrotasks();
    container.read(_serverOwnerProvider.notifier).set(_otherServer);
    await container.read(activeServerProvider.future);
    container.read(_serverOwnerProvider.notifier).set(_server);
    await container.read(activeServerProvider.future);
    loadGate.complete(
      _conversation(
        'server-chat',
        storage: ChatStorageKind.openWebUi,
        body: 'Stale server body',
      ),
    );

    final result = await selection;
    expect(result.disposition, ConversationSelectionDisposition.canceled);
    expect(container.read(activeConversationProvider)?.id, previous.id);
  });

  test('stalled OpenWebUI load fails at the selection deadline', () async {
    final previous = _conversation(
      'previous',
      storage: ChatStorageKind.directLocal,
      body: 'Previous body',
    );
    final summary = _conversation(
      'stalled-server-chat',
      storage: ChatStorageKind.openWebUi,
    );
    final loadGate = Completer<Conversation>();
    final container = await _createContainer(
      activeConversation: previous,
      timeout: const Duration(milliseconds: 50),
      extraOverrides: [
        loadConversationProvider(
          conversationScopedId(summary),
        ).overrideWith((ref) => loadGate.future),
      ],
    );
    _certifyOpenWebUiStorage(container);

    final result = await container
        .read(conversationSelectionProvider.notifier)
        .select(summary)
        .timeout(const Duration(milliseconds: 250));

    expect(result.disposition, ConversationSelectionDisposition.failed);
    expect(result.error, isA<TimeoutException>());
    expect(container.read(activeConversationProvider)?.id, previous.id);
    expect(container.read(conversationSelectionProvider).isLoading, isFalse);
  });

  test('disposing the provider cancels an in-flight selection', () async {
    final summary = _conversation(
      'disposed-selection',
      storage: ChatStorageKind.directLocal,
    );
    final loadGate = Completer<Conversation>();
    final container = await _createContainer(
      extraOverrides: [
        loadConversationProvider(
          conversationScopedId(summary),
        ).overrideWith((ref) => loadGate.future),
      ],
    );

    final selection = container
        .read(conversationSelectionProvider.notifier)
        .select(summary);
    await _flushMicrotasks();
    container.dispose();

    final result = await selection.timeout(const Duration(milliseconds: 100));
    expect(result.disposition, ConversationSelectionDisposition.canceled);
  });

  test(
    'typed ownership failures retry within the same selection intent',
    () async {
      final summary = _conversation(
        'retry-owner-chat',
        storage: ChatStorageKind.openWebUi,
      );
      final full = _conversation(
        'retry-owner-chat',
        storage: ChatStorageKind.openWebUi,
        body: 'Loaded after ownership replacement',
      );
      var attempts = 0;
      final scopedId = conversationScopedId(summary);
      final container = await _createContainer(
        extraOverrides: [
          loadConversationProvider(scopedId).overrideWith((ref) async {
            attempts += 1;
            if (attempts == 1) {
              throw OpenWebUiConversationOwnershipException(
                OpenWebUiConversationOwnershipFailureReason.changedWhileLoading,
              );
            }
            return full;
          }),
        ],
      );
      _certifyOpenWebUiStorage(container);

      final result = await container
          .read(conversationSelectionProvider.notifier)
          .select(summary);

      expect(result.disposition, ConversationSelectionDisposition.committed);
      expect(attempts, 2);
      expect(container.read(activeConversationProvider)?.id, full.id);
    },
  );

  test('repeated ownership failures are paced and remain cancelable', () async {
    final first = _conversation(
      'repeated-owner-failure',
      storage: ChatStorageKind.openWebUi,
    );
    final second = _conversation(
      'replacement',
      storage: ChatStorageKind.directLocal,
    );
    final secondFull = _conversation(
      'replacement',
      storage: ChatStorageKind.directLocal,
      body: 'Replacement body',
    );
    var attempts = 0;
    final container = await _createContainer(
      timeout: const Duration(seconds: 1),
      extraOverrides: [
        loadConversationProvider(conversationScopedId(first)).overrideWith((
          ref,
        ) async {
          attempts += 1;
          throw OpenWebUiConversationOwnershipException(
            OpenWebUiConversationOwnershipFailureReason.changedWhileLoading,
          );
        }),
        loadConversationProvider(
          conversationScopedId(second),
        ).overrideWith((ref) async => secondFull),
      ],
    );
    _certifyOpenWebUiStorage(container);

    final firstSelection = container
        .read(conversationSelectionProvider.notifier)
        .select(first);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(attempts, lessThan(10));

    final secondResult = await container
        .read(conversationSelectionProvider.notifier)
        .select(second);
    final firstResult = await firstSelection.timeout(
      const Duration(milliseconds: 100),
    );

    expect(
      secondResult.disposition,
      ConversationSelectionDisposition.committed,
    );
    expect(firstResult.disposition, ConversationSelectionDisposition.canceled);
    expect(container.read(activeConversationProvider)?.id, second.id);
  });

  test(
    'terminal failure preserves the active chat and a fresh retry succeeds',
    () async {
      final previous = _conversation(
        'previous',
        storage: ChatStorageKind.directLocal,
        body: 'Previous body',
      );
      final summary = _conversation(
        'retry-chat',
        storage: ChatStorageKind.directLocal,
      );
      final full = _conversation(
        'retry-chat',
        storage: ChatStorageKind.directLocal,
        body: 'Recovered body',
      );
      var attempts = 0;
      final scopedId = conversationScopedId(summary);
      final container = await _createContainer(
        activeConversation: previous,
        extraOverrides: [
          loadConversationProvider(scopedId).overrideWith((ref) async {
            attempts += 1;
            if (attempts == 1) throw StateError('offline');
            return full;
          }),
        ],
      );

      final first = await container
          .read(conversationSelectionProvider.notifier)
          .select(summary);
      expect(first.disposition, ConversationSelectionDisposition.failed);
      expect(first.error, isA<StateError>());
      expect(container.read(activeConversationProvider)?.id, previous.id);
      expect(container.read(conversationSelectionProvider).isLoading, isFalse);

      final second = await container
          .read(conversationSelectionProvider.notifier)
          .select(summary);
      expect(second.disposition, ConversationSelectionDisposition.committed);
      expect(attempts, 2);
      expect(container.read(activeConversationProvider)?.id, full.id);
      expect(
        container.read(activeConversationProvider)?.messages.single.content,
        'Recovered body',
      );
    },
  );
}
