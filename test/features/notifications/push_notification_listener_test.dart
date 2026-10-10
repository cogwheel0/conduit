import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/providers/notification_socket_listener.dart';
import 'package:conduit/features/notifications/providers/push_notification_listener.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/features/notifications/services/notification_router.dart';
import 'package:conduit/features/notifications/services/notification_sound_service.dart';
import 'package:conduit/features/notifications/services/notification_tap_router.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show AuthNavigationState, authNavigationStateProvider;
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/active_view_tracker.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show SettledActiveAccountId, settledActiveAccountIdProvider;
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

String _reply({String chat = 'c1', String msg = 'm1'}) => jsonEncode({
  'v': 1,
  'k': 'reply',
  'src': 'owui',
  'ids': {'chat': chat, 'msg': msg},
  't': 'Trip ideas',
  'b': 'Here are three routes.',
  'ts': 1760000000,
  'dk': 'chat:$chat:$msg',
  'g': 'chat:$chat',
});

String _hermesReply() => jsonEncode({
  'v': 1,
  'k': 'reply',
  'src': 'hermes',
  'ids': {'session': 's1', 'turn': 't1'},
  't': 'Plan',
  'b': 'Done.',
  'ts': 1760000000,
  'dk': 'hermes:s1:t1',
  'g': 'hermes:s1',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Port port;
  late _Router router;
  late List<(Object?, String)> opened;
  late ProviderContainer container;
  // Read when a launch tap first asks; a test sets them before that.
  late AuthNavigationState authNavigation;
  late String? activeAccountId;

  setUp(() {
    port = _Port();
    router = _Router();
    opened = [];
    authNavigation = AuthNavigationState.loading;
    activeAccountId = 'acct-1';
    container = ProviderContainer(
      overrides: [
        pushPlatformPortProvider.overrideWithValue(port),
        notificationRouterProvider.overrideWithValue(router),
        notificationTapRouterProvider.overrideWith(
          (ref) => _TapRouter(ref, opened),
        ),
        authNavigationStateProvider.overrideWith((ref) => authNavigation),
        settledActiveAccountIdProvider.overrideWith(
          () => _SettledAccount(activeAccountId),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(pushNotificationListenerProvider);
  });

  test('a foreground push goes to the router, already claimed', () async {
    port.emit(
      PushForegroundEvent(
        PushMessage(sid: 'sid', scope: 'owui:acct-2', payloadJson: _reply()),
      ),
    );
    await pumpEventQueue();

    check(router.routed).length.equals(1);
    final (notification, alreadyClaimed) = router.routed.single;
    check(alreadyClaimed).isTrue();
    check(notification.scope).equals('owui:acct-2');
    check(notification.kind).equals(NotificationKind.chatCompletion);
    check(notification.dedupKey).equals('owui:acct-2|chat:c1:m1');
  });

  test('a foreground test push is not shown', () async {
    port.emit(
      PushForegroundEvent(
        PushMessage(
          sid: 'sid',
          scope: 'owui:acct-2',
          payloadJson: jsonEncode({
            'v': 1,
            'k': 'test',
            'src': 'owui',
            'ids': <String, String>{},
            't': '',
            'b': '',
            'ts': 1760000000,
            'dk': 'test:n1',
            'n': 'n1',
          }),
        ),
      ),
    );
    port.emit(
      const PushForegroundEvent(
        PushMessage(sid: 'sid', scope: 'owui:acct-2', payloadJson: 'garbage'),
      ),
    );
    await pumpEventQueue();
    check(router.routed).isEmpty();
  });

  test('a tapped push opens its payload in its scope', () async {
    port.emit(PushTapEvent(PushTap(scope: 'owui:acct-2', payloadJson: _reply())));
    await pumpEventQueue();

    check(opened).length.equals(1);
    check(opened.single.$2).equals('owui:acct-2');
    check(opened.single.$1 as Map).has((m) => m['dk'], 'dk').equals(
      'chat:c1:m1',
    );
  });

  test('an Open WebUI launch tap waits for its session, then opens once', () async {
    port.launchTap = PushTap(scope: 'owui:acct-2', payloadJson: _reply());
    final listener = container.read(pushNotificationListenerProvider.notifier);

    await listener.handleLaunchTap(openWebUiReady: false);
    check(opened).isEmpty();
    await listener.handleLaunchTap(openWebUiReady: true);
    await listener.handleLaunchTap(openWebUiReady: true);

    check(opened).length.equals(1);
    check(port.launchTapTaken).equals(1);
  });

  test(
    'a launch tap for another account opens while the active one is signed out',
    () async {
      authNavigation = AuthNavigationState.needsLogin;
      port.launchTap = PushTap(scope: 'owui:acct-2', payloadJson: _reply());

      await container
          .read(pushNotificationListenerProvider.notifier)
          .handleLaunchTap(openWebUiReady: false);

      // The tap router switches to acct-2, or opens its sign-in.
      check(opened.single.$2).equals('owui:acct-2');
    },
  );

  test('a launch tap for the signed-out active account waits for it', () async {
    authNavigation = AuthNavigationState.needsLogin;
    activeAccountId = 'acct-2';
    port.launchTap = PushTap(scope: 'owui:acct-2', payloadJson: _reply());
    final listener = container.read(pushNotificationListenerProvider.notifier);

    await listener.handleLaunchTap(openWebUiReady: false);
    check(opened).isEmpty();
    await listener.handleLaunchTap(openWebUiReady: true);
    check(opened.single.$2).equals('owui:acct-2');
  });

  test('a Hermes launch tap opens at once', () async {
    port.launchTap = PushTap(scope: 'hermes:conn-1', payloadJson: _hermesReply());
    await container
        .read(pushNotificationListenerProvider.notifier)
        .handleLaunchTap(openWebUiReady: false);
    check(opened.single.$2).equals('hermes:conn-1');
  });
}

final class _Router extends NotificationRouter {
  _Router()
    : super(
        readSettings: () => const AppSettings(),
        readActiveView: () => const ActiveView(),
        isAppForeground: () => true,
        localNotifications: LocalNotificationService(),
        sound: const NotificationSoundService(),
        showInAppBanner: (_) {},
        onChannelUnread: (_) {},
      );

  final routed = <(AppNotification, bool)>[];

  @override
  Future<NotificationSurface> route(
    AppNotification notification, {
    bool alreadyClaimed = false,
  }) async {
    routed.add((notification, alreadyClaimed));
    return NotificationSurface.banner;
  }
}

final class _TapRouter extends NotificationTapRouter {
  _TapRouter(Ref ref, this.opened) : super(ref, _NoNavigator());

  final List<(Object?, String)> opened;

  @override
  Future<bool> openCp1(Object? payload, {required String scope}) async {
    opened.add((payload, scope));
    return true;
  }
}

final class _SettledAccount extends SettledActiveAccountId {
  _SettledAccount(this.accountId);

  final String? accountId;

  @override
  String? build() => accountId;
}

final class _NoNavigator implements NotificationTapNavigator {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Port extends UnsupportedPushPlatform {
  _Port();

  final _events = StreamController<PushPlatformEvent>.broadcast();
  PushTap? launchTap;
  int launchTapTaken = 0;

  void emit(PushPlatformEvent event) => _events.add(event);

  @override
  Stream<PushPlatformEvent> get events => _events.stream;

  @override
  Future<PushTap?> takeLaunchTap() async {
    launchTapTaken++;
    final tap = launchTap;
    launchTap = null;
    return tap;
  }
}
