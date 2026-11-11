import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/providers/notification_tap_listener.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/features/notifications/services/notification_tap_router.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show AuthNavigationState, authNavigationStateProvider;
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show SettledActiveAccountId, settledActiveAccountIdProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hands out [launch] as the notification that cold-launched the app.
final class _LocalNotifications extends LocalNotificationService {
  _LocalNotifications(this.launch);

  final NotificationTap? launch;

  @override
  Future<void> initialize() async {}

  @override
  Stream<NotificationTap> get taps => const Stream.empty();

  @override
  Future<NotificationTap?> launchTap() async => launch;
}

final class _TapRouter extends NotificationTapRouter {
  _TapRouter(Ref ref, this.opened) : super(ref, _NoNavigator());

  final List<NotificationTap> opened;

  @override
  Future<void> openTap(NotificationTap tap) async => opened.add(tap);
}

final class _NoNavigator implements NotificationTapNavigator {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _SettledAccount extends SettledActiveAccountId {
  _SettledAccount(this.accountId);

  final String? accountId;

  @override
  String? build() => accountId;
}

void main() {
  late List<NotificationTap> opened;

  NotificationTapListener listenerFor(
    NotificationTap launch, {
    AuthNavigationState authNavigation = AuthNavigationState.needsLogin,
    String activeAccountId = 'acct-1',
  }) {
    opened = [];
    final container = ProviderContainer(
      overrides: [
        localNotificationServiceProvider.overrideWithValue(
          _LocalNotifications(launch),
        ),
        notificationTapRouterProvider.overrideWith(
          (ref) => _TapRouter(ref, opened),
        ),
        authNavigationStateProvider.overrideWithValue(authNavigation),
        settledActiveAccountIdProvider.overrideWith(
          () => _SettledAccount(activeAccountId),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(notificationTapListenerProvider);
    return container.read(notificationTapListenerProvider.notifier);
  }

  NotificationTap chat({String? scope}) => NotificationTap(
    kind: NotificationKind.chatCompletion,
    sourceId: 'c1',
    scope: scope,
  );

  test(
    'a tap for another account opens while the active one is signed out',
    () async {
      final listener = listenerFor(chat(scope: 'owui:acct-2'));

      await listener.handleLaunchTap(openWebUiReady: false);
      await listener.handleLaunchTap(openWebUiReady: true);

      check(opened).length.equals(1);
      check(opened.single.scope).equals('owui:acct-2');
    },
  );

  test('a tap for the active account waits for its session', () async {
    final listener = listenerFor(chat(scope: 'owui:acct-1'));

    await listener.handleLaunchTap(openWebUiReady: false);
    check(opened).isEmpty();
    await listener.handleLaunchTap(openWebUiReady: true);
    check(opened).length.equals(1);
  });

  test('a tap from before scopes waits for the active session', () async {
    final listener = listenerFor(chat());

    await listener.handleLaunchTap(openWebUiReady: false);
    check(opened).isEmpty();
  });

  test('another account waits while the active session may still come', () async {
    final listener = listenerFor(
      chat(scope: 'owui:acct-2'),
      authNavigation: AuthNavigationState.loading,
    );

    await listener.handleLaunchTap(openWebUiReady: false);
    check(opened).isEmpty();
    await listener.handleLaunchTap(openWebUiReady: true);
    check(opened).length.equals(1);
  });

  test('a Hermes tap opens at once', () async {
    final listener = listenerFor(
      chat(scope: 'hermes:conn-1'),
      authNavigation: AuthNavigationState.loading,
    );

    await listener.handleLaunchTap(openWebUiReady: false);
    check(opened.single.scope).equals('hermes:conn-1');
  });
}
