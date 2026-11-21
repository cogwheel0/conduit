import 'package:checks/checks.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart'
    show kHermesTransport;
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/features/web_embed/web_embed_media_account.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/services/direct_replay_output.dart'
    show kConduitDirectTransport;
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

Conversation _chat(String id, {Map<String, dynamic> metadata = const {}}) =>
    Conversation(
      id: id,
      title: 'Chat',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      metadata: metadata,
    );

ChatMessage _reply({Map<String, dynamic>? metadata}) => ChatMessage(
  id: 'r1',
  role: 'assistant',
  content: '',
  timestamp: DateTime(2026),
  metadata: metadata,
);

void main() {
  group('webEmbedCameFromOpenWebUiChat', () {
    test('an Open WebUI chat, saved or temporary, hands its embeds on', () {
      for (final conversation in [
        _chat('c1'),
        annotateConversationStorage(_chat('c2'), ChatStorageKind.openWebUi),
        _chat('local:t1'),
      ]) {
        check(
          because: conversation.id,
          webEmbedCameFromOpenWebUiChat(conversation, message: _reply()),
        ).isTrue();
      }
    });

    test('a reply the Open WebUI server ran, however it streamed', () {
      for (final transport in ChatCompletionTransport.values) {
        check(
          because: transport.name,
          webEmbedCameFromOpenWebUiChat(
            _chat('c1'),
            message: _reply(metadata: {'transport': transport.name}),
          ),
        ).isTrue();
      }
    });

    test('no other backend does, nor a reply another backend ran', () {
      final cases = <String, (Conversation?, ChatMessage)>{
        'no chat': (null, _reply()),
        'Hermes': (_chat('${kHermesSessionConversationIdPrefix}s1'), _reply()),
        'Direct': (
          annotateConversationStorage(_chat('d1'), ChatStorageKind.directLocal),
          _reply(),
        ),
        'unsaved Direct': (
          _chat('d2', metadata: {'backend': 'direct'}),
          _reply(),
        ),
        'LibreChat': (
          annotateConversationStorage(_chat('l1'), ChatStorageKind.libreChat),
          _reply(),
        ),
        'direct reply': (
          _chat('c1'),
          _reply(metadata: {'transport': kConduitDirectTransport}),
        ),
        'Hermes reply': (
          _chat('c1'),
          _reply(metadata: {'transport': kHermesTransport}),
        ),
        'LibreChat reply': (
          _chat('c1'),
          _reply(metadata: {'transport': kLibreChatTransport}),
        ),
        "an unknown backend's reply": (
          _chat('c1'),
          _reply(metadata: {'transport': 'anotherBackend'}),
        ),
      };
      for (final MapEntry(key: name, value: (conversation, message))
          in cases.entries) {
        check(
          because: name,
          webEmbedCameFromOpenWebUiChat(conversation, message: message),
        ).isFalse();
      }
    });
  });

  group('webEmbedMediaAccountProvider', () {
    const server = ServerConfig(
      id: 'synthetic',
      name: 'Synthetic',
      url: 'https://chat.example.test',
    );

    ProviderContainer container({
      bool authenticated = true,
      PrimaryAccountKind primary = PrimaryAccountKind.openWebUi,
    }) {
      final api = ApiService(
        serverConfig: server,
        workerManager: WorkerManager(),
      );
      addTearDown(api.dispose);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          isAuthenticatedProvider2.overrideWithValue(authenticated),
          primaryAccountKindProvider.overrideWithValue(primary),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => _Session(ref.watch(_token)),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('is the signed-in Open WebUI account and its session', () {
      final scope = container();

      final account = scope.read(webEmbedMediaAccountProvider);
      check(account?.server).equals(server);
      check(account).equals(scope.read(webEmbedMediaAccountProvider));

      scope.read(_token.notifier).set('another-account');
      check(scope.read(webEmbedMediaAccountProvider))
        ..isNotNull()
        ..not((it) => it.equals(account));
    });

    test('is none while signed out or while LibreChat owns the Chats tab', () {
      check(container(authenticated: false).read(webEmbedMediaAccountProvider))
          .isNull();
      check(
        container(primary: PrimaryAccountKind.libreChat)
            .read(webEmbedMediaAccountProvider),
      ).isNull();
    });
  });
}

final _token = NotifierProvider<_Token, String>(_Token.new);

final class _Token extends Notifier<String> {
  @override
  String build() => 'synthetic-account';

  void set(String value) => state = value;
}

/// An auth-session epoch: a new one per session.
final class _Session {
  _Session(this.token);

  final String token;
}
