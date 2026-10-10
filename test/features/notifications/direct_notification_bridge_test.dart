import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/providers/direct_notification_bridge.dart';
import 'package:conduit/features/notifications/providers/notification_socket_listener.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/features/notifications/services/notification_router.dart';
import 'package:conduit/features/notifications/services/notification_sound_service.dart';
import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind;
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/active_view_tracker.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _reply({String? error}) => ChatMessage(
  id: 'assistant-1',
  role: 'assistant',
  content: '**Done.** The answer is 42.',
  timestamp: DateTime(2026, 10, 10),
  error: error == null ? null : ChatMessageError(content: error),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settings = AppSettings(
    notificationsEnabled: true,
    notificationInAppBanner: true,
    notificationChatEnabled: true,
  );

  late List<AppNotification> shown;
  late DirectRunRegistry registry;
  late ProviderContainer container;

  void start({ActiveView view = const ActiveView()}) {
    shown = [];
    registry = DirectRunRegistry();
    final router = NotificationRouter(
      readSettings: () => settings,
      readActiveView: () => view,
      isAppForeground: () => true,
      localNotifications: LocalNotificationService(),
      sound: const NotificationSoundService(),
      showInAppBanner: shown.add,
      onChannelUnread: (_) {},
    );
    container = ProviderContainer(
      overrides: [
        directRunRegistryProvider.overrideWithValue(registry),
        notificationRouterProvider.overrideWithValue(router),
      ],
    );
    addTearDown(container.dispose);
    container.read(directNotificationBridgeProvider);
  }

  Future<void> announce(DirectRunCompletion completion) async {
    final reservation = registry.reserve((
      ownerConversationId: 'owner',
      assistantMessageId: completion.assistantMessageId,
    ), 'profile');
    registry.announceCompletion(reservation, completion);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('a finished Direct reply is routed as a direct notification', () async {
    start();
    await announce(
      DirectRunCompletion(
        conversationId: 'direct-local:1',
        message: _reply(),
        runId: 'run-1',
        title: 'Trip ideas',
        storage: ChatStorageKind.directLocal,
      ),
    );

    check(shown).length.equals(1);
    final n = shown.single;
    check(n.kind).equals(NotificationKind.chatCompletion);
    check(n.scope).equals('direct');
    check(n.sourceId).equals('direct-local:1');
    check(n.title).equals('Trip ideas');
    check(n.body).equals('Done. The answer is 42.');
    check(
      n.dedupKey,
    ).equals('direct|direct:direct-local:1:assistant-1:run-1');
  });

  test('a failed Direct reply is routed as replyFailed', () async {
    start();
    await announce(
      DirectRunCompletion(
        conversationId: 'direct-local:1',
        message: _reply(error: 'boom'),
        runId: 'run-1',
        storage: ChatStorageKind.directLocal,
      ),
    );

    check(shown.single.kind).equals(NotificationKind.replyFailed);
  });

  test('nothing shows while that chat is on screen', () async {
    start(view: const ActiveView(chatId: 'direct-local:1'));
    await announce(
      DirectRunCompletion(
        conversationId: 'direct-local:1',
        message: _reply(),
        runId: 'run-1',
        storage: ChatStorageKind.directLocal,
      ),
    );

    check(shown).isEmpty();
  });
}
