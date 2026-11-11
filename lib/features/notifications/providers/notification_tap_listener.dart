import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/features/notifications/models/notification_scope.dart';

import '../services/local_notification_service.dart';
import '../services/notification_tap_router.dart';

part 'notification_tap_listener.g.dart';

/// Opens tapped system notifications through [NotificationTapRouter].
///
/// Alive from app start, whichever backends are in use: a Hermes or Direct
/// notification is tapped with no Open WebUI session at all, and switching
/// or signing out of an account must not drop taps for the others.
@Riverpod(keepAlive: true)
class NotificationTapListener extends _$NotificationTapListener {
  bool _launchTapHandled = false;

  @override
  void build() {
    final local = ref.read(localNotificationServiceProvider);
    // Initialize the plugin (channel + tap handler) without requesting
    // permission — permission is requested on master-toggle opt-in.
    unawaited(local.initialize());
    // System-notification taps while the app runs route to the target.
    final subscription = local.taps.listen((tap) {
      unawaited(ref.read(notificationTapRouterProvider).openTap(tap));
    });
    ref.onDispose(subscription.cancel);
  }

  /// Opens the notification that cold-launched the app, once.
  ///
  /// [openWebUiReady] says the active Open WebUI account's session is up. A
  /// tap into an Open WebUI account waits for a call that says so; one for
  /// Hermes or Direct opens on the first call.
  Future<void> handleLaunchTap({required bool openWebUiReady}) async {
    if (_launchTapHandled) return;
    final local = ref.read(localNotificationServiceProvider);
    // Ensure the plugin finished native init before querying the launch
    // intent: on Android getNotificationAppLaunchDetails() returns null until
    // then, so racing it would silently drop the deep link. initialize() is
    // idempotent and shares the in-flight future started in build().
    await local.initialize();
    final tap = await local.launchTap();
    if (tap == null || _launchTapHandled || !ref.mounted) return;
    final scope = NotificationScope.tryParse(tap.scope);
    final needsOpenWebUi =
        tap.scope == null || scope is OpenWebUiNotificationScope;
    if (needsOpenWebUi && !openWebUiReady) return;
    _launchTapHandled = true;
    await ref.read(notificationTapRouterProvider).openTap(tap);
  }
}
