// Characterization tests for the chat mutation-ownership primitives in
// `lib/features/chat/providers/chat_providers.dart`.
//
// These pin CURRENT OBSERVED behaviour so the block can be moved verbatim into
// a `part` file without silently changing anything. The owner *scope strings*
// are a cross-part contract with no other direct assertions, so their exact
// formats are pinned below.
//
// Pinned formats (see `ChatStorageIdentity.scopedId` and
// `chatMutationOwnerScopeForConversation`):
//   OpenWebUI / directLocal storage:
//     conduit-chat://scoped/v1/<32 lowercase hex runtime nonce>/<ChatStorageKind.name>/<Uri.encodeComponent(rawId)>
//   Unstored direct-transport conversation:
//     conduit-direct-runtime://<Uri.encodeComponent(rawId)>
//   Unstored native Hermes conversation:
//     conduit-hermes-runtime://<Uri.encodeComponent(rawId)>

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// An active-conversation notifier whose state is set directly, so these tests
/// characterize the ownership primitives rather than `ActiveConversationNotifier.set`.
class _StaticActive extends ActiveConversationNotifier {
  _StaticActive(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;

  void put(Conversation? next) => state = next;
}

class _TestMessagesNotifier extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const <ChatMessage>[];

  @override
  void setMessages(List<ChatMessage> messages) {
    state = List<ChatMessage>.from(messages);
  }
}

class _StubApi extends ApiService {
  _StubApi(String id)
    : super(
        serverConfig: ServerConfig(
          id: id,
          name: id,
          url: 'https://$id.example.test',
        ),
        workerManager: WorkerManager(),
      );
}

class _StubSocket extends SocketService {
  _StubSocket(String id)
    : super(
        serverConfig: ServerConfig(
          id: id,
          name: id,
          url: 'https://$id.example.test',
        ),
      );

  @override
  bool get isConnected => false;
}

Conversation _plain(String id, {Map<String, dynamic> metadata = const {}}) =>
    Conversation(
      id: id,
      title: id,
      createdAt: DateTime.utc(2026, 7, 13),
      updatedAt: DateTime.utc(2026, 7, 13),
      metadata: metadata,
    );

Conversation _stored(
  String id,
  ChatStorageKind storage, {
  Map<String, dynamic> metadata = const {},
}) => withChatStorageProvenance(_plain(id, metadata: metadata), storage);

Conversation _directRuntime(String id) =>
    _plain(id, metadata: const <String, dynamic>{'backend': kDirectTransport});

Conversation _hermesRuntime(String id) =>
    markNativeHermesConversation(_plain(id));

ChatMessage _assistant(String id) => ChatMessage(
  id: id,
  role: 'assistant',
  content: '',
  timestamp: DateTime.utc(2026, 7, 13),
);

const String _scopedVersionPrefix = 'conduit-chat://scoped/v1/';

/// Extracts the runtime nonce from a scoped id while pinning the overall shape.
String _runtimeNonceOf(String scope) {
  check(scope).startsWith(_scopedVersionPrefix);
  final remainder = scope.substring(_scopedVersionPrefix.length);
  final nonce = remainder.substring(0, remainder.indexOf('/'));
  // 16 random bytes rendered as lowercase hex.
  check(nonce).matchesPattern(RegExp(r'^[0-9a-f]{32}$'));
  return nonce;
}

ProviderContainer _container({
  AppDatabase? database,
  ApiService? api,
  Object? authEpoch,
  Conversation? active,
  SocketService? socket,
  List<ChatMessage> messages = const <ChatMessage>[],
}) {
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      apiServiceProvider.overrideWithValue(api),
      socketServiceProvider.overrideWithValue(socket),
      openWebUiAuthSessionEpochProvider.overrideWithValue(
        authEpoch ?? Object(),
      ),
      activeConversationProvider.overrideWith(() => _StaticActive(active)),
      chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
    ],
  );
  container.read(chatMessagesProvider.notifier).setMessages(messages);
  return container;
}

void _setActive(ProviderContainer container, Conversation? next) {
  (container.read(activeConversationProvider.notifier) as _StaticActive).put(
    next,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('owner scope strings', () {
    test('openWebUiChatMutationOwnerScope pins the scoped-id format', () {
      final scope = openWebUiChatMutationOwnerScope('chat-1');
      final nonce = _runtimeNonceOf(scope);

      check(scope).equals('$_scopedVersionPrefix$nonce/openWebUi/chat-1');
      // The nonce is minted once per runtime, so scopes are stable in-process.
      check(openWebUiChatMutationOwnerScope('chat-1')).equals(scope);
      check(openWebUiChatMutationOwnerScope('chat-2'))
          .equals('$_scopedVersionPrefix$nonce/openWebUi/chat-2');
    });

    test('scoped ids percent-encode the raw chat id and round-trip', () {
      const rawId = 'a/b c?d#e&f';
      final scope = openWebUiChatMutationOwnerScope(rawId);
      final nonce = _runtimeNonceOf(scope);

      check(
        scope,
      ).equals('$_scopedVersionPrefix$nonce/openWebUi/a%2Fb%20c%3Fd%23e%26f');
      final parsed = ChatStorageIdentity.parse(scope);
      check(parsed.rawId).equals(rawId);
      check(parsed.storage).equals(ChatStorageKind.openWebUi);
    });

    test('OpenWebUI-stored conversations use the openWebUi scope', () {
      final conversation = _stored('stored-owui', ChatStorageKind.openWebUi);
      final scope = chatMutationOwnerScopeForConversation(conversation);
      final nonce = _runtimeNonceOf(scope);

      check(scope).equals('$_scopedVersionPrefix$nonce/openWebUi/stored-owui');
      check(scope).equals(openWebUiChatMutationOwnerScope('stored-owui'));
    });

    test('direct-local storage uses a distinct directLocal scope', () {
      const id = 'colliding-id';
      final scope = chatMutationOwnerScopeForConversation(
        _stored(id, ChatStorageKind.directLocal),
      );
      final nonce = _runtimeNonceOf(scope);

      check(scope).equals('$_scopedVersionPrefix$nonce/directLocal/$id');
      check(scope).not((it) => it.equals(openWebUiChatMutationOwnerScope(id)));
    });

    test('temporary "local:" chats get no special branch', () {
      // `isTemporaryChat` is just a `local:` id prefix; the ownership scope has
      // no temporary-chat branch, so the colon is percent-encoded like any
      // other raw-id character.
      const temporaryId = 'local:9f2c1d3e';
      final scope = openWebUiChatMutationOwnerScope(temporaryId);
      final nonce = _runtimeNonceOf(scope);

      check(scope)
          .equals('$_scopedVersionPrefix$nonce/openWebUi/local%3A9f2c1d3e');
      check(chatMutationOwnerScopeForConversation(_plain(temporaryId)))
          .equals(scope);
      check(
        chatMutationOwnerScopeForConversation(
          _stored(temporaryId, ChatStorageKind.openWebUi),
        ),
      ).equals(scope);
      check(chatMutationOwnerScopeForConversation(_directRuntime(temporaryId)))
          .equals('conduit-direct-runtime://local%3A9f2c1d3e');
      check(
        chatMutationOwnerScopeForConversation(
          _hermesRuntime('local:hermes_abc'),
        ),
      ).equals('conduit-hermes-runtime://local%3Ahermes_abc');
    });

    test('unstored direct-transport conversations use a literal scope', () {
      check(
        chatMutationOwnerScopeForConversation(_directRuntime('direct-chat')),
      ).equals('conduit-direct-runtime://direct-chat');
      check(chatMutationOwnerScopeForConversation(_directRuntime('a/b c')))
          .equals('conduit-direct-runtime://a%2Fb%20c');
    });

    test('unstored native Hermes conversations use a literal scope', () {
      check(
        chatMutationOwnerScopeForConversation(_hermesRuntime('hermes-chat')),
      ).equals('conduit-hermes-runtime://hermes-chat');
      check(chatMutationOwnerScopeForConversation(_hermesRuntime('a/b c')))
          .equals('conduit-hermes-runtime://a%2Fb%20c');
    });

    test('unannotated conversations fall back to OpenWebUI ownership', () {
      final conversation = _plain('unannotated');
      check(chatMutationOwnerScopeForConversation(conversation))
          .equals(openWebUiChatMutationOwnerScope('unannotated'));
    });

    test('a hermes backend marker without the runtime mark falls back to OpenWebUI', () {
      // LOOKS WRONG (pinned as-is): only `isNativeHermesConversation`, an
      // Expando set by this process, routes to the Hermes namespace. A
      // deserialized conversation carrying `backend: hermes` is treated as
      // OpenWebUI-owned.
      final conversation = _plain(
        'hermes-metadata-only',
        metadata: const <String, dynamic>{'backend': 'hermes'},
      );
      check(chatMutationOwnerScopeForConversation(conversation))
          .equals(openWebUiChatMutationOwnerScope('hermes-metadata-only'));
    });

    test('storage provenance outranks the transport backend marker', () {
      final storedOpenWebUi = _stored(
        'direct-turn-in-owui',
        ChatStorageKind.openWebUi,
        metadata: const <String, dynamic>{'backend': kDirectTransport},
      );
      check(chatMutationOwnerScopeForConversation(storedOpenWebUi))
          .equals(openWebUiChatMutationOwnerScope('direct-turn-in-owui'));

      final storedDirectLocal = _stored(
        'direct-turn-local',
        ChatStorageKind.directLocal,
        metadata: const <String, dynamic>{'backend': kDirectTransport},
      );
      final scope = chatMutationOwnerScopeForConversation(storedDirectLocal);
      check(scope).equals(
        '$_scopedVersionPrefix${_runtimeNonceOf(scope)}/directLocal/direct-turn-local',
      );
    });

    test('the direct backend branch is checked before the Hermes mark', () {
      final conversation = markNativeHermesConversation(
        _plain(
          'both-markers',
          metadata: const <String, dynamic>{'backend': kDirectTransport},
        ),
      );
      check(chatMutationOwnerScopeForConversation(conversation))
          .equals('conduit-direct-runtime://both-markers');
    });

    test('the scope ignores everything except id, storage and backend', () {
      // Titles, timestamps and unrelated metadata are not part of ownership.
      final a = withChatStorageProvenance(
        Conversation(
          id: 'same-id',
          title: 'A',
          createdAt: DateTime.utc(2020),
          updatedAt: DateTime.utc(2020),
          metadata: const <String, dynamic>{'unrelated': 1},
        ),
        ChatStorageKind.openWebUi,
      );
      final b = withChatStorageProvenance(
        Conversation(
          id: 'same-id',
          title: 'B',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        ChatStorageKind.openWebUi,
      );
      check(chatMutationOwnerScopeForConversation(a))
          .equals(chatMutationOwnerScopeForConversation(b));
    });
  });

  group('captureChatMutationOwner / ChatMutationOwnerToken', () {
    test('an OpenWebUI conversation captures the whole context tuple', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final api = _StubApi('owui');
      final epoch = Object();
      final conversation = _stored('owui-chat', ChatStorageKind.openWebUi);
      final container = _container(database: db, api: api, authEpoch: epoch);
      addTearDown(container.dispose);

      final token = captureChatMutationOwner(container, conversation);

      check(token.conversation).identicalTo(conversation);
      check(token.ownerConversationId)
          .equals(openWebUiChatMutationOwnerScope('owui-chat'));
      check(token.usesOpenWebUiContext).isTrue();
      check(token.openWebUiDatabase).identicalTo(db);
      check(token.openWebUiApi).identicalTo(api);
      check(token.openWebUiAuthSessionEpoch).identicalTo(epoch);
      check(token.openWebUiAuthSnapshot).isNotNull();
    });

    test('a null conversation still captures the OpenWebUI context', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final api = _StubApi('owui');
      final epoch = Object();
      final container = _container(database: db, api: api, authEpoch: epoch);
      addTearDown(container.dispose);

      final token = captureChatMutationOwner(container, null);

      check(token.conversation).isNull();
      check(token.ownerConversationId).isNull();
      check(token.usesOpenWebUiContext).isTrue();
      check(token.openWebUiDatabase).identicalTo(db);
      check(token.openWebUiApi).identicalTo(api);
      check(token.openWebUiAuthSessionEpoch).identicalTo(epoch);
    });

    test('an unannotated conversation is treated as OpenWebUI-owned', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(database: db, api: _StubApi('owui'));
      addTearDown(container.dispose);

      final token = captureChatMutationOwner(container, _plain('unannotated'));

      check(token.usesOpenWebUiContext).isTrue();
      check(token.openWebUiDatabase).identicalTo(db);
    });

    test('non-OpenWebUI owners capture no OpenWebUI context at all', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(database: db, api: _StubApi('owui'));
      addTearDown(container.dispose);

      for (final conversation in <Conversation>[
        _stored('x', ChatStorageKind.directLocal),
        _directRuntime('x'),
        _hermesRuntime('x'),
      ]) {
        final token = captureChatMutationOwner(container, conversation);
        check(token.usesOpenWebUiContext).isFalse();
        check(token.openWebUiDatabase).isNull();
        check(token.openWebUiApi).isNull();
        check(token.openWebUiAuthSnapshot).isNull();
        check(token.openWebUiAuthSessionEpoch).isNull();
        check(token.ownerConversationId)
            .equals(chatMutationOwnerScopeForConversation(conversation));
      }
    });

    test('an absent API yields a null api and a null auth snapshot', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(database: db, api: null);
      addTearDown(container.dispose);

      final token = captureChatMutationOwner(
        container,
        _stored('owui-chat', ChatStorageKind.openWebUi),
      );

      check(token.usesOpenWebUiContext).isTrue();
      check(token.openWebUiApi).isNull();
      check(token.openWebUiAuthSnapshot).isNull();
      check(token.openWebUiDatabase).identicalTo(db);
    });

    test('tokens compare by identity only - there is no value equality', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(database: db, api: _StubApi('owui'));
      addTearDown(container.dispose);
      final conversation = _stored('owui-chat', ChatStorageKind.openWebUi);

      final first = captureChatMutationOwner(container, conversation);
      final second = captureChatMutationOwner(container, conversation);

      check(first).identicalTo(first);
      check(first == second).isFalse();
      check(first).not((it) => it.equals(second));
      // Only the fields, not the tokens, are comparable.
      check(second.ownerConversationId).equals(first.ownerConversationId);
      check(second.openWebUiDatabase).identicalTo(first.openWebUiDatabase);
    });
  });

  group('chatMutationTokenStillActive', () {
    test('holds while an equivalent OpenWebUI conversation stays active', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final active = _stored('owui-chat', ChatStorageKind.openWebUi);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: active,
      );
      addTearDown(container.dispose);

      final token = captureChatMutationOwner(container, active);
      check(chatMutationTokenStillActive(container, token)).isTrue();

      // A different instance with the same id and storage still owns the chat.
      _setActive(container, _stored('owui-chat', ChatStorageKind.openWebUi));
      check(chatMutationTokenStillActive(container, token)).isTrue();
    });

    test('an OpenWebUI token fails closed when the API instance changes', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final epoch = Object();
      final active = _stored('owui-chat', ChatStorageKind.openWebUi);
      final container = _container(
        database: db,
        api: _StubApi('owui-a'),
        authEpoch: epoch,
        active: active,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, active);

      container.updateOverrides([
        appDatabaseProvider.overrideWithValue(db),
        apiServiceProvider.overrideWithValue(_StubApi('owui-b')),
        socketServiceProvider.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
        activeConversationProvider.overrideWith(() => _StaticActive(active)),
        chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
      ]);

      check(chatMutationTokenStillActive(container, token)).isFalse();
    });

    test('an OpenWebUI token fails closed when the database changes', () {
      final dbA = AppDatabase(NativeDatabase.memory());
      addTearDown(dbA.close);
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      final api = _StubApi('owui');
      final epoch = Object();
      final active = _stored('owui-chat', ChatStorageKind.openWebUi);
      final container = _container(
        database: dbA,
        api: api,
        authEpoch: epoch,
        active: active,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, active);

      container.updateOverrides([
        appDatabaseProvider.overrideWithValue(dbB),
        apiServiceProvider.overrideWithValue(api),
        socketServiceProvider.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
        activeConversationProvider.overrideWith(() => _StaticActive(active)),
        chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
      ]);

      check(chatMutationTokenStillActive(container, token)).isFalse();
    });

    test('an OpenWebUI token fails closed when the auth epoch changes', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final api = _StubApi('owui');
      final active = _stored('owui-chat', ChatStorageKind.openWebUi);
      final container = _container(
        database: db,
        api: api,
        authEpoch: Object(),
        active: active,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, active);

      container.updateOverrides([
        appDatabaseProvider.overrideWithValue(db),
        apiServiceProvider.overrideWithValue(api),
        socketServiceProvider.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        activeConversationProvider.overrideWith(() => _StaticActive(active)),
        chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
      ]);

      check(chatMutationTokenStillActive(container, token)).isFalse();
    });

    test('a direct-local token ignores API and database swaps', () {
      // LOOKS WRONG (pinned as-is): the account/database fence only runs for
      // OpenWebUI owners, so a direct-local token survives a full server swap
      // as long as the scoped conversation id still matches.
      final dbA = AppDatabase(NativeDatabase.memory());
      addTearDown(dbA.close);
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      final active = _stored('local-chat', ChatStorageKind.directLocal);
      final container = _container(
        database: dbA,
        api: _StubApi('owui-a'),
        active: active,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, active);

      container.updateOverrides([
        appDatabaseProvider.overrideWithValue(dbB),
        apiServiceProvider.overrideWithValue(_StubApi('owui-b')),
        socketServiceProvider.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        activeConversationProvider.overrideWith(() => _StaticActive(active)),
        chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
      ]);

      check(chatMutationTokenStillActive(container, token)).isTrue();
    });

    test('a colliding id in the other storage never satisfies the token', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final active = _stored('same-id', ChatStorageKind.openWebUi);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: active,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, active);

      _setActive(container, _stored('same-id', ChatStorageKind.directLocal));
      check(chatMutationTokenStillActive(container, token)).isFalse();

      _setActive(container, _directRuntime('same-id'));
      check(chatMutationTokenStillActive(container, token)).isFalse();
    });

    test('a null-conversation token means "no conversation is active"', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(database: db, api: _StubApi('owui'));
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, null);

      check(chatMutationTokenStillActive(container, token)).isTrue();

      _setActive(container, _stored('any', ChatStorageKind.openWebUi));
      check(chatMutationTokenStillActive(container, token)).isFalse();
    });

    test('a conversation token fails once the active chat is cleared', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final active = _stored('owui-chat', ChatStorageKind.openWebUi);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: active,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, active);

      _setActive(container, null);
      check(chatMutationTokenStillActive(container, token)).isFalse();
    });

    test('a direct-runtime token tracks only the direct-runtime scope', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final active = _directRuntime('runtime-chat');
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: active,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, active);

      check(chatMutationTokenStillActive(container, token)).isTrue();
      _setActive(container, _directRuntime('runtime-chat'));
      check(chatMutationTokenStillActive(container, token)).isTrue();
      _setActive(container, _stored('runtime-chat', ChatStorageKind.openWebUi));
      check(chatMutationTokenStillActive(container, token)).isFalse();
    });

    test('an OpenWebUI token follows a matching in-place remap', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final origin = _stored('local-id', ChatStorageKind.openWebUi);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: origin,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, origin);

      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: 'local-id', toId: 'server-id');
      _setActive(container, _stored('server-id', ChatStorageKind.openWebUi));

      check(chatMutationTokenStillActive(container, token)).isTrue();
    });

    test('a remap in another namespace does not transfer ownership', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final origin = _stored('local-id', ChatStorageKind.openWebUi);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: origin,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, origin);

      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(
            fromId: 'local-id',
            toId: 'server-id',
            namespace: ActiveConversationRemapNamespace.hermes,
          );
      _setActive(container, _stored('server-id', ChatStorageKind.openWebUi));

      check(chatMutationTokenStillActive(container, token)).isFalse();
    });

    test('a remap recorded for other ids does not transfer ownership', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final origin = _stored('local-id', ChatStorageKind.openWebUi);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: origin,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, origin);

      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: 'other-local-id', toId: 'server-id');
      _setActive(container, _stored('server-id', ChatStorageKind.openWebUi));

      check(chatMutationTokenStillActive(container, token)).isFalse();
    });

    test('a remap onto direct-local storage does not transfer ownership', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final origin = _stored('local-id', ChatStorageKind.openWebUi);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: origin,
      );
      addTearDown(container.dispose);
      final token = captureChatMutationOwner(container, origin);

      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: 'local-id', toId: 'server-id');
      _setActive(container, _stored('server-id', ChatStorageKind.directLocal));

      check(chatMutationTokenStillActive(container, token)).isFalse();
    });
  });

  group('chatMutationOwnerScopeIsActive', () {
    test('false when no conversation is active', () {
      final container = _container();
      addTearDown(container.dispose);

      check(
        chatMutationOwnerScopeIsActive(
          container,
          openWebUiChatMutationOwnerScope('anything'),
        ),
      ).isFalse();
    });

    test('true only for the exact scope of the active conversation', () {
      final container = _container(
        active: _stored('owui-chat', ChatStorageKind.openWebUi),
      );
      addTearDown(container.dispose);

      check(
        chatMutationOwnerScopeIsActive(
          container,
          openWebUiChatMutationOwnerScope('owui-chat'),
        ),
      ).isTrue();
      // The raw id is not a scope; it never matches.
      check(chatMutationOwnerScopeIsActive(container, 'owui-chat')).isFalse();
      check(
        chatMutationOwnerScopeIsActive(
          container,
          chatMutationOwnerScopeForConversation(
            _stored('owui-chat', ChatStorageKind.directLocal),
          ),
        ),
      ).isFalse();
    });

    test('runtime scopes match their own namespace only', () {
      final container = _container(active: _directRuntime('runtime-chat'));
      addTearDown(container.dispose);

      check(
        chatMutationOwnerScopeIsActive(
          container,
          'conduit-direct-runtime://runtime-chat',
        ),
      ).isTrue();
      check(
        chatMutationOwnerScopeIsActive(
          container,
          'conduit-hermes-runtime://runtime-chat',
        ),
      ).isFalse();
      check(
        chatMutationOwnerScopeIsActive(
          container,
          openWebUiChatMutationOwnerScope('runtime-chat'),
        ),
      ).isFalse();
    });

    test('ignores the database and API entirely', () {
      // LOOKS WRONG (pinned as-is): unlike `chatMutationTokenStillActive`, a
      // bare scope string carries no account context, so the same scope stays
      // "active" after the whole OpenWebUI context is swapped.
      final dbA = AppDatabase(NativeDatabase.memory());
      addTearDown(dbA.close);
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      final active = _stored('owui-chat', ChatStorageKind.openWebUi);
      final container = _container(
        database: dbA,
        api: _StubApi('owui-a'),
        active: active,
      );
      addTearDown(container.dispose);
      final scope = openWebUiChatMutationOwnerScope('owui-chat');

      container.updateOverrides([
        appDatabaseProvider.overrideWithValue(dbB),
        apiServiceProvider.overrideWithValue(_StubApi('owui-b')),
        socketServiceProvider.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        activeConversationProvider.overrideWith(() => _StaticActive(active)),
        chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
      ]);

      check(chatMutationOwnerScopeIsActive(container, scope)).isTrue();
    });
  });

  group('captureOpenWebUiCompletionOwner / OpenWebUiCompletionOwner', () {
    test('captures the container context when nothing is passed', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final api = _StubApi('owui');
      final epoch = Object();
      final container = _container(database: db, api: api, authEpoch: epoch);
      addTearDown(container.dispose);

      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      check(owner.chatId).equals('owui-chat');
      check(owner.database).identicalTo(db);
      check(owner.api).identicalTo(api);
      check(owner.authSessionEpoch).identicalTo(epoch);
      check(owner.contextWasCoherent).isTrue();
    });

    test('explicit database and api arguments win over the providers', () {
      final dbProvider = AppDatabase(NativeDatabase.memory());
      addTearDown(dbProvider.close);
      final dbExplicit = AppDatabase(NativeDatabase.memory());
      addTearDown(dbExplicit.close);
      final apiExplicit = _StubApi('explicit');
      final container = _container(
        database: dbProvider,
        api: _StubApi('from-provider'),
      );
      addTearDown(container.dispose);

      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
        database: dbExplicit,
        api: apiExplicit,
      );

      check(owner.database).identicalTo(dbExplicit);
      check(owner.api).identicalTo(apiExplicit);
      // ...which immediately makes the owner stale against its own container.
      check(openWebUiCompletionContextIsCurrent(container, owner)).isFalse();
    });

    test('chatId is mutable while every other field is final', () {
      final container = _container();
      addTearDown(container.dispose);

      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'before',
      );
      // LOOKS WRONG (pinned as-is): `OpenWebUiCompletionOwner.chatId` is a
      // non-final field, so callers can retarget a captured owner in place.
      owner.chatId = 'after';
      check(owner.chatId).equals('after');
    });

    test('a null API is coherent, and the socket is never consulted', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final socket = _StubSocket('some-server');
      addTearDown(socket.dispose);
      final container = _container(database: db, api: null, socket: socket);
      addTearDown(container.dispose);

      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      // `_readOpenWebUiSocketForApi` returns null unless the api is an
      // ApiService, so an unpaired socket cannot make the tuple incoherent.
      check(owner.api).isNull();
      check(owner.contextWasCoherent).isTrue();
      check(openWebUiCompletionContextIsCurrent(container, owner)).isTrue();
    });

    test('a socket for another server is dropped, not flagged incoherent', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final socket = _StubSocket('server-b');
      addTearDown(socket.dispose);
      final container = _container(
        database: db,
        api: _StubApi('server-a'),
        socket: socket,
      );
      addTearDown(container.dispose);

      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      // `_readOpenWebUiSocketForApi` drops the mismatched socket, so the tuple
      // is still considered coherent.
      check(owner.contextWasCoherent).isTrue();
    });

    test('a matching socket keeps the tuple coherent', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final socket = _StubSocket('server-a');
      addTearDown(socket.dispose);
      final container = _container(
        database: db,
        api: _StubApi('server-a'),
        socket: socket,
      );
      addTearDown(container.dispose);

      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      check(owner.contextWasCoherent).isTrue();
      check(openWebUiCompletionContextIsCurrent(container, owner)).isTrue();
    });

    test('a non-ApiService api argument is captured but never coherent', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(database: db, api: null);
      addTearDown(container.dispose);
      final sentinel = Object();

      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
        api: sentinel,
      );

      check(owner.api).identicalTo(sentinel);
      check(owner.contextWasCoherent).isFalse();
      check(openWebUiCompletionContextIsCurrent(container, owner)).isFalse();
    });
  });

  group('openWebUiCompletionContextIsCurrent', () {
    test('an incoherent capture can never become current again', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final api = _StubApi('owui');
      final epoch = Object();
      final container = _container(database: db, api: api, authEpoch: epoch);
      addTearDown(container.dispose);

      final owner = OpenWebUiCompletionOwner(
        chatId: 'owui-chat',
        database: db,
        api: api,
        contextWasCoherent: false,
        authSessionEpoch: epoch,
      );

      check(openWebUiCompletionContextIsCurrent(container, owner)).isFalse();
    });

    test('a hand-built coherent owner matching the container is current', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final api = _StubApi('owui');
      final epoch = Object();
      final container = _container(database: db, api: api, authEpoch: epoch);
      addTearDown(container.dispose);

      final owner = OpenWebUiCompletionOwner(
        chatId: 'owui-chat',
        database: db,
        api: api,
        contextWasCoherent: true,
        authSessionEpoch: epoch,
      );

      check(openWebUiCompletionContextIsCurrent(container, owner)).isTrue();
    });

    test('false after the API, database or auth epoch changes', () {
      final dbA = AppDatabase(NativeDatabase.memory());
      addTearDown(dbA.close);
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      final apiA = _StubApi('owui-a');
      final epoch = Object();
      final container = _container(database: dbA, api: apiA, authEpoch: epoch);
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );
      check(openWebUiCompletionContextIsCurrent(container, owner)).isTrue();

      void reconfigure({
        required AppDatabase database,
        required ApiService api,
        required Object authEpoch,
      }) {
        container.updateOverrides([
          appDatabaseProvider.overrideWithValue(database),
          apiServiceProvider.overrideWithValue(api),
          socketServiceProvider.overrideWithValue(null),
          openWebUiAuthSessionEpochProvider.overrideWithValue(authEpoch),
          activeConversationProvider.overrideWith(() => _StaticActive(null)),
          chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
        ]);
      }

      reconfigure(database: dbB, api: apiA, authEpoch: epoch);
      check(openWebUiCompletionContextIsCurrent(container, owner)).isFalse();

      reconfigure(database: dbA, api: _StubApi('owui-b'), authEpoch: epoch);
      check(openWebUiCompletionContextIsCurrent(container, owner)).isFalse();

      reconfigure(database: dbA, api: apiA, authEpoch: Object());
      check(openWebUiCompletionContextIsCurrent(container, owner)).isFalse();

      reconfigure(database: dbA, api: apiA, authEpoch: epoch);
      check(openWebUiCompletionContextIsCurrent(container, owner)).isTrue();
    });
  });

  group('activeOpenWebUiChatIdForMutation', () {
    test('returns the owner id while that OpenWebUI chat is active', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: _stored('owui-chat', ChatStorageKind.openWebUi),
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      check(activeOpenWebUiChatIdForMutation(container, owner))
          .equals('owui-chat');
    });

    test('null when no conversation is active', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(database: db, api: _StubApi('owui'));
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      check(activeOpenWebUiChatIdForMutation(container, owner)).isNull();
    });

    test('null when a colliding non-OpenWebUI chat is active', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: _stored('owui-chat', ChatStorageKind.directLocal),
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      check(activeOpenWebUiChatIdForMutation(container, owner)).isNull();

      _setActive(container, _directRuntime('owui-chat'));
      check(activeOpenWebUiChatIdForMutation(container, owner)).isNull();
    });

    test('an unannotated active chat still counts as OpenWebUI-owned', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: _plain('owui-chat'),
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      check(activeOpenWebUiChatIdForMutation(container, owner))
          .equals('owui-chat');
    });

    test('null once the OpenWebUI context is stale', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final active = _stored('owui-chat', ChatStorageKind.openWebUi);
      final container = _container(
        database: db,
        api: _StubApi('owui-a'),
        active: active,
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      container.updateOverrides([
        appDatabaseProvider.overrideWithValue(db),
        apiServiceProvider.overrideWithValue(_StubApi('owui-b')),
        socketServiceProvider.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        activeConversationProvider.overrideWith(() => _StaticActive(active)),
        chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
      ]);

      check(activeOpenWebUiChatIdForMutation(container, owner)).isNull();
    });

    test('follows a matching in-place remap to the new server id', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: _stored('local-id', ChatStorageKind.openWebUi),
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'local-id',
      );

      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: 'local-id', toId: 'server-id');
      _setActive(container, _stored('server-id', ChatStorageKind.openWebUi));

      check(activeOpenWebUiChatIdForMutation(container, owner))
          .equals('server-id');
    });

    test('null for a remap with other ids or another namespace', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: _stored('local-id', ChatStorageKind.openWebUi),
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'local-id',
      );

      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: 'someone-else', toId: 'server-id');
      _setActive(container, _stored('server-id', ChatStorageKind.openWebUi));
      check(activeOpenWebUiChatIdForMutation(container, owner)).isNull();

      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(
            fromId: 'local-id',
            toId: 'server-id',
            namespace: ActiveConversationRemapNamespace.direct,
          );
      check(activeOpenWebUiChatIdForMutation(container, owner)).isNull();
    });
  });

  group('resolveOpenWebUiCompletionChatId', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> seedChat(String chatId, {String? assistantId}) async {
      await db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: chatId,
              title: chatId,
              createdAt: 1,
              updatedAt: 1,
              bodySynced: const Value(true),
            ),
          );
      if (assistantId == null) return;
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: assistantId,
              chatId: chatId,
              role: 'assistant',
              content: '',
              createdAt: 1,
              orderIndex: 1,
              payload: '{}',
            ),
          );
    }

    test('returns the recorded id when the durable row owns it', () async {
      await seedChat('owui-chat', assistantId: 'assistant-1');
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: _stored('owui-chat', ChatStorageKind.openWebUi),
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      check(
        await resolveOpenWebUiCompletionChatId(
          container,
          owner: owner,
          assistantMessageId: 'assistant-1',
        ),
      ).equals('owui-chat');
    });

    test('returns the recorded id when the durable row is missing', () async {
      await seedChat('owui-chat');
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: _stored('owui-chat', ChatStorageKind.openWebUi),
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );

      check(
        await resolveOpenWebUiCompletionChatId(
          container,
          owner: owner,
          assistantMessageId: 'absent-assistant',
        ),
      ).equals('owui-chat');
    });

    test('a database failure is swallowed and the recorded id wins', () async {
      await seedChat('owui-chat', assistantId: 'assistant-1');
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: _stored('owui-chat', ChatStorageKind.openWebUi),
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'owui-chat',
      );
      await db.close();

      check(
        await resolveOpenWebUiCompletionChatId(
          container,
          owner: owner,
          assistantMessageId: 'assistant-1',
        ),
      ).equals('owui-chat');
    });

    test('an inline request with no database follows the active remap when it '
        'still owns the placeholder', () async {
      final container = _container(
        database: null,
        api: null,
        active: _stored('local-id', ChatStorageKind.openWebUi),
        messages: <ChatMessage>[_assistant('assistant-1')],
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'local-id',
      );
      check(owner.database).isNull();

      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: 'local-id', toId: 'server-id');
      _setActive(container, _stored('server-id', ChatStorageKind.openWebUi));

      check(
        await resolveOpenWebUiCompletionChatId(
          container,
          owner: owner,
          assistantMessageId: 'assistant-1',
        ),
      ).equals('server-id');
    });

    test(
      'the remap is not followed when the UI no longer holds the placeholder',
      () async {
        final container = _container(
          database: null,
          api: null,
          active: _stored('local-id', ChatStorageKind.openWebUi),
          messages: const <ChatMessage>[],
        );
        addTearDown(container.dispose);
        final owner = captureOpenWebUiCompletionOwner(
          container,
          chatId: 'local-id',
        );

        container
            .read(activeConversationInPlaceRemapProvider.notifier)
            .mark(fromId: 'local-id', toId: 'server-id');
        _setActive(container, _stored('server-id', ChatStorageKind.openWebUi));

        check(
          await resolveOpenWebUiCompletionChatId(
            container,
            owner: owner,
            assistantMessageId: 'assistant-1',
          ),
        ).equals('local-id');
      },
    );

    test('a user-role placeholder never satisfies the remap path', () async {
      final container = _container(
        database: null,
        api: null,
        active: _stored('local-id', ChatStorageKind.openWebUi),
        messages: <ChatMessage>[
          ChatMessage(
            id: 'assistant-1',
            role: 'user',
            content: '',
            timestamp: DateTime.utc(2026, 7, 13),
          ),
        ],
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'local-id',
      );

      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: 'local-id', toId: 'server-id');
      _setActive(container, _stored('server-id', ChatStorageKind.openWebUi));

      check(
        await resolveOpenWebUiCompletionChatId(
          container,
          owner: owner,
          assistantMessageId: 'assistant-1',
        ),
      ).equals('local-id');
    });

    test('durable ownership outranks the active remap', () async {
      await seedChat('local-id', assistantId: 'assistant-1');
      final container = _container(
        database: db,
        api: _StubApi('owui'),
        active: _stored('local-id', ChatStorageKind.openWebUi),
        messages: <ChatMessage>[_assistant('assistant-1')],
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'local-id',
      );

      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: 'local-id', toId: 'server-id');
      _setActive(container, _stored('server-id', ChatStorageKind.openWebUi));

      check(
        await resolveOpenWebUiCompletionChatId(
          container,
          owner: owner,
          assistantMessageId: 'assistant-1',
        ),
      ).equals('local-id');
    });

    test('a stale OpenWebUI context blocks the remap fallback', () async {
      final container = _container(
        database: null,
        api: null,
        active: _stored('local-id', ChatStorageKind.openWebUi),
        messages: <ChatMessage>[_assistant('assistant-1')],
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: 'local-id',
      );
      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: 'local-id', toId: 'server-id');
      _setActive(container, _stored('server-id', ChatStorageKind.openWebUi));

      container.updateOverrides([
        appDatabaseProvider.overrideWithValue(null),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        activeConversationProvider.overrideWith(
          () => _StaticActive(_stored('server-id', ChatStorageKind.openWebUi)),
        ),
        chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
      ]);
      container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
        _assistant('assistant-1'),
      ]);

      check(
        await resolveOpenWebUiCompletionChatId(
          container,
          owner: owner,
          assistantMessageId: 'assistant-1',
        ),
      ).equals('local-id');
    });
  });
}
