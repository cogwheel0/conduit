import 'package:checks/checks.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/active_view_tracker.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/features/notifications/services/notification_router.dart';
import 'package:conduit/features/notifications/services/notification_sound_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockLocalNotifications extends Mock
    implements LocalNotificationService {}

class _MockSound extends Mock implements NotificationSoundService {}

AppNotification _chat({
  String id = 'chat-1',
  String key = 'k-chat',
  String scope = 'owui:acct-1',
  NotificationKind kind = NotificationKind.chatCompletion,
}) => AppNotification(
  kind: kind,
  scope: scope,
  title: 'Title',
  body: 'Body',
  sourceId: id,
  dedupKey: key,
);

AppNotification _channel({String id = 'chan-1', String key = 'k-chan'}) =>
    AppNotification(
      kind: NotificationKind.channelMessage,
      scope: 'owui:acct-1',
      title: 'Ada',
      body: 'hi',
      sourceId: id,
      dedupKey: key,
    );

AppNotification _hermes({
  String session = 's-1',
  String key = 'k-hermes',
  String connection = 'conn-1',
  NotificationKind kind = NotificationKind.chatCompletion,
}) => AppNotification(
  kind: kind,
  scope: 'hermes:$connection',
  title: 'Plan',
  body: 'Done.',
  sourceId: session,
  dedupKey: key,
  group: 'hermes:$session',
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
    notificationScheduledEnabled: true,
  );

  // Viewing nothing, in account acct-1 and Hermes connection conn-1.
  const home = ActiveView(
    openWebUiAccountId: 'acct-1',
    hermesConnectionId: 'conn-1',
  );

  setUpAll(() {
    registerFallbackValue(_chat());
  });

  late _MockLocalNotifications local;
  late _MockSound sound;
  late List<AppNotification> banners;
  late List<AppNotification> unreads;
  late List<(String, String?)> claims;
  late bool claimResult;
  late DateTime now;

  setUp(() {
    local = _MockLocalNotifications();
    sound = _MockSound();
    banners = [];
    unreads = [];
    claims = [];
    claimResult = true;
    now = DateTime(2026, 10, 10, 12);
    var nextId = 0;
    when(() => local.nextNotificationId()).thenAnswer((_) => ++nextId);
    when(
      () => local.show(
        any(),
        playSound: any(named: 'playSound'),
        id: any(named: 'id'),
      ),
    ).thenAnswer((_) async {});
    when(() => sound.play()).thenAnswer((_) async {});
  });

  NotificationRouter build({
    AppSettings settings = allOn,
    ActiveView view = home,
    bool foreground = true,
  }) => NotificationRouter(
    readSettings: () => settings,
    readActiveView: () => view,
    isAppForeground: () => foreground,
    localNotifications: local,
    sound: sound,
    showInAppBanner: banners.add,
    onChannelUnread: unreads.add,
    claim: (key, localId) async {
      claims.add((key, localId));
      return claimResult;
    },
    now: () => now,
  );

  void verifyNeverShown() => verifyNever(
    () => local.show(
      any(),
      playSound: any(named: 'playSound'),
      id: any(named: 'id'),
    ),
  );

  group('gating', () {
    test('master toggle off suppresses everything', () async {
      final router = build(
        settings: allOn.copyWith(notificationsEnabled: false),
      );
      final surface = await router.route(_chat());
      check(surface).equals(NotificationSurface.suppressed);
      check(banners).isEmpty();
      verifyNeverShown();
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
      check(await router.route(_channel()))
          .equals(NotificationSurface.suppressed);
    });

    test('duplicate dedupKey is suppressed on the second delivery', () async {
      final router = build();
      check(await router.route(_chat(key: 'dup')))
          .equals(NotificationSurface.banner);
      check(await router.route(_chat(key: 'dup')))
          .equals(NotificationSurface.suppressed);
    });

    test('currently viewing the chat suppresses its completion', () async {
      final router = build(
        view: const ActiveView(chatId: 'chat-1', openWebUiAccountId: 'acct-1'),
      );
      check(await router.route(_chat(id: 'chat-1')))
          .equals(NotificationSurface.suppressed);
    });

    test('currently viewing the channel suppresses its message', () async {
      final router = build(
        view: const ActiveView(
          channelId: 'chan-1',
          openWebUiAccountId: 'acct-1',
        ),
      );
      check(await router.route(_channel(id: 'chan-1')))
          .equals(NotificationSurface.suppressed);
    });

    test(
      'backgrounded, the active chat still notifies (not suppressed)',
      () async {
        // Start a chat (it is the active view), then background the app: the
        // completion must still fire an OS notification.
        final router = build(
          foreground: false,
          view: const ActiveView(
            chatId: 'chat-1',
            openWebUiAccountId: 'acct-1',
          ),
        );
        check(await router.route(_chat(id: 'chat-1')))
            .equals(NotificationSurface.system);
      },
    );
  });

  group('surface selection', () {
    test('foreground shows an in-app banner only', () async {
      final router = build(foreground: true);
      check(await router.route(_chat())).equals(NotificationSurface.banner);
      check(banners).length.equals(1);
      verifyNeverShown();
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
      verify(
        () => local.show(
          any(),
          playSound: any(named: 'playSound'),
          id: any(named: 'id'),
        ),
      ).called(1);
    });

    test(
      'system notification sound follows the notificationSound pref',
      () async {
        final router = build(
          foreground: false,
          settings: allOn.copyWith(notificationSound: false),
        );
        await router.route(_chat());
        final played =
            verify(
                  () => local.show(
                    any(),
                    playSound: captureAny(named: 'playSound'),
                    id: any(named: 'id'),
                  ),
                ).captured.single
                as bool;
        check(played).isFalse();
      },
    );

    test('background with system off is silent', () async {
      final router = build(
        foreground: false,
        settings: allOn.copyWith(notificationSystem: false),
      );
      check(await router.route(_chat())).equals(NotificationSurface.silent);
      verifyNeverShown();
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
  group('kinds', () {
    test('a failed reply follows the chat toggle', () async {
      final failed = _chat(kind: NotificationKind.replyFailed);
      check(await build().route(failed)).equals(NotificationSurface.banner);
      final off = build(
        settings: allOn.copyWith(notificationChatEnabled: false),
      );
      check(
        await off.route(_chat(kind: NotificationKind.replyFailed, key: 'f2')),
      ).equals(NotificationSurface.suppressed);
    });

    test('a scheduled task follows its own toggle', () async {
      final task = _hermes(kind: NotificationKind.scheduledTask, key: 'cron');
      check(await build().route(task)).equals(NotificationSurface.banner);
      final off = build(
        settings: allOn.copyWith(
          notificationScheduledEnabled: false,
          notificationChatEnabled: true,
        ),
      );
      check(
        await off.route(
          _hermes(kind: NotificationKind.scheduledTask, key: 'cron-2'),
        ),
      ).equals(NotificationSurface.suppressed);
    });

    test('a test push is never surfaced', () async {
      final router = build(foreground: false);
      check(
        await router.route(_chat(kind: NotificationKind.pushTest)),
      ).equals(NotificationSurface.suppressed);
      verifyNeverShown();
      check(claims).isEmpty();
    });
  });

  group('scope-aware viewing', () {
    test('the same chat id in another account still notifies', () async {
      final router = build(
        view: const ActiveView(chatId: 'chat-1', openWebUiAccountId: 'acct-2'),
      );
      check(
        await router.route(_chat(id: 'chat-1')),
      ).equals(NotificationSurface.banner);
    });

    test('the open Hermes session suppresses its reply', () async {
      final router = build(
        view: const ActiveView(
          hermesConnectionId: 'conn-1',
          hermesSessionId: 's-1',
        ),
      );
      check(
        await router.route(_hermes()),
      ).equals(NotificationSurface.suppressed);
    });

    test('the same session on another connection still notifies', () async {
      final router = build(
        view: const ActiveView(
          hermesConnectionId: 'conn-2',
          hermesSessionId: 's-1',
        ),
      );
      check(await router.route(_hermes())).equals(NotificationSurface.banner);
    });

    test('a Direct reply is suppressed while its chat is open', () async {
      final router = build(
        view: const ActiveView(chatId: 'direct-local:1'),
      );
      check(
        await router.route(
          _chat(id: 'direct-local:1', scope: 'direct', key: 'direct|d'),
        ),
      ).equals(NotificationSurface.suppressed);
    });
  });

  group('claim', () {
    test('a system notification is claimed under its key and id', () async {
      final router = build(foreground: false);
      check(
        await router.route(_chat(key: 'owui:acct-1|chat:c:m')),
      ).equals(NotificationSurface.system);
      check(claims).deepEquals([('owui:acct-1|chat:c:m', '1')]);
      final posted = verify(
        () => local.show(
          any(),
          playSound: any(named: 'playSound'),
          id: captureAny(named: 'id'),
        ),
      ).captured.single;
      check(posted).equals(1);
    });

    test('a key another source claimed is not posted', () async {
      claimResult = false;
      final router = build(foreground: false);
      check(await router.route(_chat())).equals(NotificationSurface.suppressed);
      verifyNeverShown();
    });

    test('banners are not claimed', () async {
      await build(foreground: true).route(_chat());
      check(claims).isEmpty();
    });

    test('a push the extension already claimed is posted unclaimed', () async {
      claimResult = false;
      final router = build(foreground: false);
      check(
        await router.route(_chat(), alreadyClaimed: true),
      ).equals(NotificationSurface.system);
      check(claims).isEmpty();
    });
  });

  group('Hermes session window', () {
    test('another reply for the session within 120 s is dropped', () async {
      final router = build();
      check(
        await router.route(_hermes(key: 'hermes:conn-1|hermes:s-1:local-a')),
      ).equals(NotificationSurface.banner);
      now = now.add(const Duration(seconds: 119));
      check(
        await router.route(_hermes(key: 'hermes:conn-1|hermes:s-1:turn-7')),
      ).equals(NotificationSurface.suppressed);
    });

    test('after the window the session notifies again', () async {
      final router = build();
      await router.route(_hermes(key: 'a'));
      now = now.add(NotificationRouter.hermesGroupWindow);
      check(
        await router.route(_hermes(key: 'b')),
      ).equals(NotificationSurface.banner);
    });

    test('other sessions and connections are not held back', () async {
      final router = build();
      await router.route(_hermes(key: 'a'));
      check(
        await router.route(_hermes(key: 'b', session: 's-2')),
      ).equals(NotificationSurface.banner);
      check(
        await router.route(_hermes(key: 'c', connection: 'conn-2')),
      ).equals(NotificationSurface.banner);
    });

    test('Open WebUI replies in one chat are not grouped', () async {
      final router = build();
      AppNotification reply(String key) => _chat(key: key).copyWith(
        group: 'chat:chat-1',
      );
      check(await router.route(reply('a'))).equals(NotificationSurface.banner);
      check(await router.route(reply('b'))).equals(NotificationSurface.banner);
    });
  });
}
