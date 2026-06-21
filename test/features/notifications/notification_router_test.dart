import 'package:checks/checks.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/notifications/models/app_notification.dart';
import 'package:conduit/features/notifications/services/active_view_tracker.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/features/notifications/services/notification_router.dart';
import 'package:conduit/features/notifications/services/notification_sound_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockLocalNotifications extends Mock implements LocalNotificationService {}

class _MockSound extends Mock implements NotificationSoundService {}

AppNotification _chat({String id = 'chat-1', String key = 'k-chat'}) =>
    AppNotification(
      kind: NotificationKind.chatCompletion,
      title: 'Title',
      body: 'Body',
      sourceId: id,
      dedupKey: key,
    );

AppNotification _channel({String id = 'chan-1', String key = 'k-chan'}) =>
    AppNotification(
      kind: NotificationKind.channelMessage,
      title: 'Ada',
      body: 'hi',
      sourceId: id,
      dedupKey: key,
    );

void main() {
  // Master + both kinds + both sound flags on; surfaces on. Tests override.
  const allOn = AppSettings(
    notificationsEnabled: true,
    notificationSound: true,
    notificationSoundAlways: true,
    notificationInAppBanner: true,
    notificationSystem: true,
    notificationChatEnabled: true,
    notificationChannelEnabled: true,
  );

  setUpAll(() {
    registerFallbackValue(_chat());
  });

  late _MockLocalNotifications local;
  late _MockSound sound;
  late List<AppNotification> banners;
  late List<AppNotification> unreads;

  setUp(() {
    local = _MockLocalNotifications();
    sound = _MockSound();
    banners = [];
    unreads = [];
    when(() => local.show(any(), playSound: any(named: 'playSound'))).thenAnswer((_) async {});
    when(() => sound.play()).thenAnswer((_) async {});
  });

  NotificationRouter build({
    AppSettings settings = allOn,
    ActiveView view = const ActiveView(),
    bool foreground = true,
  }) => NotificationRouter(
    readSettings: () => settings,
    readActiveView: () => view,
    isAppForeground: () => foreground,
    localNotifications: local,
    sound: sound,
    showInAppBanner: banners.add,
    onChannelUnread: unreads.add,
  );

  group('gating', () {
    test('master toggle off suppresses everything', () async {
      final router = build(
        settings: allOn.copyWith(notificationsEnabled: false),
      );
      final surface = await router.route(_chat());
      check(surface).equals(NotificationSurface.suppressed);
      check(banners).isEmpty();
      verifyNever(() => local.show(any(), playSound: any(named: 'playSound')));
      verifyNever(() => sound.play());
    });

    test('per-kind chat toggle off suppresses chat completions', () async {
      final router = build(
        settings: allOn.copyWith(notificationChatEnabled: false),
      );
      check(await router.route(_chat())).equals(NotificationSurface.suppressed);
    });

    test('per-kind channel toggle off suppresses channel messages', () async {
      final router = build(
        settings: allOn.copyWith(notificationChannelEnabled: false),
      );
      check(
        await router.route(_channel()),
      ).equals(NotificationSurface.suppressed);
    });

    test('duplicate dedupKey is suppressed on the second delivery', () async {
      final router = build();
      check(await router.route(_chat(key: 'dup'))).equals(
        NotificationSurface.banner,
      );
      check(
        await router.route(_chat(key: 'dup')),
      ).equals(NotificationSurface.suppressed);
    });

    test('currently viewing the chat suppresses its completion', () async {
      final router = build(view: const ActiveView(chatId: 'chat-1'));
      check(
        await router.route(_chat(id: 'chat-1')),
      ).equals(NotificationSurface.suppressed);
    });

    test('currently viewing the channel suppresses its message', () async {
      final router = build(view: const ActiveView(channelId: 'chan-1'));
      check(
        await router.route(_channel(id: 'chan-1')),
      ).equals(NotificationSurface.suppressed);
    });

    test('backgrounded, the active chat still notifies (not suppressed)', () async {
      // Start a chat (it is the active view), then background the app: the
      // completion must still fire an OS notification.
      final router = build(
        foreground: false,
        view: const ActiveView(chatId: 'chat-1'),
      );
      check(
        await router.route(_chat(id: 'chat-1')),
      ).equals(NotificationSurface.system);
    });
  });

  group('surface selection', () {
    test('foreground shows an in-app banner only', () async {
      final router = build(foreground: true);
      check(await router.route(_chat())).equals(NotificationSurface.banner);
      check(banners).length.equals(1);
      verifyNever(() => local.show(any(), playSound: any(named: 'playSound')));
    });

    test('foreground with banners off is silent', () async {
      final router = build(
        foreground: true,
        settings: allOn.copyWith(notificationInAppBanner: false),
      );
      check(await router.route(_chat())).equals(NotificationSurface.silent);
      check(banners).isEmpty();
    });

    test('background posts a system notification only', () async {
      final router = build(foreground: false);
      check(await router.route(_chat())).equals(NotificationSurface.system);
      check(banners).isEmpty();
      verify(() => local.show(any(), playSound: any(named: 'playSound'))).called(1);
    });

    test('system notification sound follows the notificationSound pref', () async {
      final router = build(
        foreground: false,
        settings: allOn.copyWith(notificationSound: false),
      );
      await router.route(_chat());
      final played =
          verify(
                () => local.show(any(), playSound: captureAny(named: 'playSound')),
              ).captured.single
              as bool;
      check(played).isFalse();
    });

    test('background with system off is silent', () async {
      final router = build(
        foreground: false,
        settings: allOn.copyWith(notificationSystem: false),
      );
      check(await router.route(_chat())).equals(NotificationSurface.silent);
      verifyNever(() => local.show(any(), playSound: any(named: 'playSound')));
    });
  });

  group('side effects', () {
    test('sound plays only when sound AND soundAlways are on', () async {
      final router = build();
      await router.route(_chat());
      verify(() => sound.play()).called(1);
    });

    test('sound does not play when soundAlways is off', () async {
      final router = build(
        settings: allOn.copyWith(notificationSoundAlways: false),
      );
      await router.route(_chat());
      verifyNever(() => sound.play());
    });

    test('channel messages bump unread; chat completions do not', () async {
      final router = build();
      await router.route(_channel());
      await router.route(_chat());
      check(unreads).length.equals(1);
      check(unreads.single.kind).equals(NotificationKind.channelMessage);
    });

    test('suppressed notifications have no side effects', () async {
      final router = build(
        settings: allOn.copyWith(notificationsEnabled: false),
      );
      await router.route(_channel());
      check(unreads).isEmpty();
      verifyNever(() => sound.play());
    });
  });
}
