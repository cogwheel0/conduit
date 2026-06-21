import 'package:checks/checks.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/notifications/services/open_webui_notification_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _serverConfig = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
);

final _timestamp = DateTime(2026, 1, 1, 12);

final _notificationRouterProvider = Provider<OpenWebUINotificationRouter>(
  OpenWebUINotificationRouter.new,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OpenWebUINotificationRouter.openChat', () {
    test('hydrates active state from a fetched persisted chat', () async {
      final router = _attachRouter();
      final messages = [_message('user-1', 'user', 'Hello')];
      final api = _FakeApiService({
        'chat-api': _conversation('chat-api', messages: messages),
      });
      final container = _createContainer(api: api);

      container.read(temporaryChatEnabledProvider.notifier).set(true);
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('previous-chat'));
      container.read(chatMessagesProvider.notifier).setMessages([
        _message('stale', 'assistant', 'Old'),
      ]);

      await container.read(_notificationRouterProvider).openChat('chat-api');

      check(api.requestedIds).deepEquals(['chat-api']);
      check(container.read(temporaryChatEnabledProvider)).isFalse();
      check(container.read(activeConversationProvider)?.id).equals('chat-api');
      check(container.read(activeConversationProvider)?.lastReadAt).isNotNull();
      check(
        container.read(chatMessagesProvider).map((m) => m.id).toList(),
      ).deepEquals(['user-1']);
      check(container.read(isLoadingConversationProvider)).isFalse();
      check(_location(router)).equals(Routes.chat);
    });

    test('uses cached conversations when offline', () async {
      final router = _attachRouter();
      final messages = [_message('assistant-1', 'assistant', 'Cached answer')];
      final container = _createContainer(
        conversations: [_conversation('cached-chat', messages: messages)],
      );

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('previous-chat'));
      container.read(chatMessagesProvider.notifier).setMessages([
        _message('stale', 'assistant', 'Old'),
      ]);

      await container.read(_notificationRouterProvider).openChat('cached-chat');

      check(
        container.read(activeConversationProvider)?.id,
      ).equals('cached-chat');
      check(container.read(activeConversationProvider)?.lastReadAt).isNotNull();
      check(
        container.read(chatMessagesProvider).map((m) => m.id).toList(),
      ).deepEquals(['assistant-1']);
      check(container.read(isLoadingConversationProvider)).isFalse();
      check(_location(router)).equals(Routes.chat);
    });

    test(
      're-opens the active temporary chat without clearing messages',
      () async {
        final router = _attachRouter();
        final messages = [
          _message('temp-user', 'user', 'Temporary prompt'),
          _message('temp-assistant', 'assistant', 'Temporary answer'),
        ];
        final temporaryConversation = _conversation(
          'local:session-1',
          messages: messages,
        );
        final container = _createContainer();

        container
            .read(activeConversationProvider.notifier)
            .set(temporaryConversation);
        container.read(chatMessagesProvider.notifier).setMessages([
          _message('stale', 'assistant', 'Old'),
        ]);
        container.read(temporaryChatEnabledProvider.notifier).set(false);

        await container
            .read(_notificationRouterProvider)
            .openChat('local:session-1');

        check(
          container.read(activeConversationProvider)?.id,
        ).equals('local:session-1');
        check(container.read(temporaryChatEnabledProvider)).isTrue();
        check(
          container.read(chatMessagesProvider).map((m) => m.id).toList(),
        ).deepEquals(['temp-user', 'temp-assistant']);
        check(container.read(isLoadingConversationProvider)).isFalse();
        check(_location(router)).equals(Routes.chat);
      },
    );

    test(
      'ignores stale temporary chat taps without destructive clears',
      () async {
        final router = _attachRouter(initialLocation: '/start');
        final messages = [_message('current', 'assistant', 'Keep me')];
        final container = _createContainer();

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('current-chat', messages: messages));
        container.read(chatMessagesProvider.notifier).setMessages(messages);
        container.read(temporaryChatEnabledProvider.notifier).set(false);

        await container
            .read(_notificationRouterProvider)
            .openChat('local:missing');

        check(
          container.read(activeConversationProvider)?.id,
        ).equals('current-chat');
        check(container.read(temporaryChatEnabledProvider)).isFalse();
        check(
          container.read(chatMessagesProvider).map((m) => m.id).toList(),
        ).deepEquals(['current']);
        check(container.read(isLoadingConversationProvider)).isFalse();
        check(_location(router)).equals('/start');
      },
    );
  });
}

ProviderContainer _createContainer({
  ApiService? api,
  List<Conversation> conversations = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWithValue(const AppSettings()),
      appDatabaseProvider.overrideWithValue(null),
      apiServiceProvider.overrideWithValue(api),
      conversationsProvider.overrideWith(
        () => _TestConversations(conversations),
      ),
      isAuthenticatedProvider2.overrideWithValue(true),
      reviewerModeProvider.overrideWithValue(false),
      socketServiceProvider.overrideWithValue(null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

GoRouter _attachRouter({String initialLocation = '/start'}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/start',
        builder: (context, state) => const SizedBox.shrink(),
      ),
      GoRoute(
        path: Routes.chat,
        builder: (context, state) => const SizedBox.shrink(),
      ),
    ],
  );
  NavigationService.attachRouter(router);
  addTearDown(router.dispose);
  return router;
}

String _location(GoRouter router) =>
    router.routeInformationProvider.value.uri.toString();

ChatMessage _message(String id, String role, String content) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    timestamp: _timestamp,
  );
}

Conversation _conversation(String id, {List<ChatMessage> messages = const []}) {
  return Conversation(
    id: id,
    title: id,
    createdAt: _timestamp,
    updatedAt: _timestamp,
    messages: messages,
  );
}

class _TestConversations extends Conversations {
  _TestConversations(this._conversations);

  final List<Conversation> _conversations;

  @override
  Future<List<Conversation>> build() async => _conversations;
}

class _FakeApiService extends ApiService {
  _FakeApiService(this._conversations)
    : super(serverConfig: _serverConfig, workerManager: WorkerManager());

  final Map<String, Conversation> _conversations;
  final List<String> requestedIds = [];

  @override
  Future<Conversation> getConversation(String id) async {
    requestedIds.add(id);
    final conversation = _conversations[id];
    if (conversation == null) {
      throw StateError('Missing conversation $id');
    }
    return conversation;
  }
}
