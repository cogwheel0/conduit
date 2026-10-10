import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/providers/hermes_notification_bridge.dart';
import 'package:conduit/features/notifications/providers/notification_socket_listener.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/features/notifications/services/notification_router.dart';
import 'package:conduit/features/notifications/services/notification_sound_service.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/active_view_tracker.dart';
import 'package:conduit_core/features/notifications/services/cp1_notification_mapper.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settings = AppSettings(
    notificationsEnabled: true,
    notificationInAppBanner: true,
    notificationChatEnabled: true,
  );

  late List<AppNotification> shown;
  late HermesRunRegistry registry;
  late NotificationRouter router;

  setUp(() {
    shown = [];
    registry = HermesRunRegistry();
    router = NotificationRouter(
      readSettings: () => settings,
      readActiveView: () => const ActiveView(hermesConnectionId: 'conn-1'),
      isAppForeground: () => true,
      localNotifications: LocalNotificationService(),
      sound: const NotificationSoundService(),
      showInAppBanner: shown.add,
      onChannelUnread: (_) {},
    );
    final container = ProviderContainer(
      overrides: [
        hermesRunRegistryProvider.overrideWithValue(registry),
        notificationRouterProvider.overrideWithValue(router),
      ],
    );
    addTearDown(container.dispose);
    container.read(hermesNotificationBridgeProvider);
  });

  HermesTurnCompletion turn() => HermesTurnCompletion(
    connectionId: 'conn-1',
    sessionId: '20261010_101500_ab12cd',
    title: 'Refactor plan',
    message: ChatMessage(
      id: 'assistant-1',
      role: 'assistant',
      content: 'Done. I split the parser into three modules.',
      timestamp: DateTime(2026, 10, 10),
    ),
  );

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('a finished Hermes turn is routed for its connection', () async {
    registry.announceCompletion(turn());
    await settle();

    check(shown).length.equals(1);
    final n = shown.single;
    check(n.scope).equals('hermes:conn-1');
    check(n.sourceId).equals('20261010_101500_ab12cd');
    check(n.title).equals('Refactor plan');
    check(n.group).equals('hermes:20261010_101500_ab12cd');
  });

  test('the push for the same turn that follows is dropped', () async {
    registry.announceCompletion(turn());
    await settle();
    final push = appNotificationFromCp1({
      'v': 1,
      'k': 'reply',
      'src': 'hermes',
      'ids': {'session': '20261010_101500_ab12cd', 'turn': 't-7'},
      't': 'Refactor plan',
      'b': 'Done.',
      'ts': 1760000000,
      'dk': 'hermes:20261010_101500_ab12cd:t-7',
      'g': 'hermes:20261010_101500_ab12cd',
    }, scope: 'hermes:conn-1')!;

    check(await router.route(push)).equals(NotificationSurface.suppressed);
    check(shown).length.equals(1);
  });
}
