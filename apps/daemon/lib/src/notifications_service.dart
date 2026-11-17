import 'dart:async';

import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/notification_policy.dart';
import 'package:conduit_core/features/notifications/services/notification_prefs_sync.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'account_scope.dart';
import 'event_bus.dart';

/// `notifications.*`: the phone's Notifications page over core's
/// `AppSettings`, and core's gating chain for each notification the window
/// is about to show.
///
/// Every write goes through the `AppSettingsNotifier` setter the phone
/// calls; the master toggle, Sound and Sound Always are then mirrored to the
/// Open WebUI account, as the phone mirrors them. `notifications.changed`
/// follows the notifier, whoever changed it (the server's mirror at sign-in
/// too).
final class NotificationsService {
  NotificationsService(this._container, {EventBus? events}) {
    if (events != null) {
      _container.listen<AppSettings>(appSettingsProvider, (previous, next) {
        if (previous != null && _dto(previous) == _dto(next)) return;
        events.emit(ConduitEventSpecs.notificationsChanged, null);
      });
    }
  }

  final ProviderContainer _container;

  AppSettingsNotifier get _notifier =>
      _container.read(appSettingsProvider.notifier);

  static NotificationSettingsDto _dto(AppSettings s, {bool synced = false}) =>
      NotificationSettingsDto(
        enabled: s.notificationsEnabled,
        sound: s.notificationSound,
        soundAlways: s.notificationSoundAlways,
        inAppBanner: s.notificationInAppBanner,
        system: s.notificationSystem,
        answers: s.notificationChatEnabled,
        channels: s.notificationChannelEnabled,
        mentionsOnly: s.notificationChannelMentionsOnly,
        synced: synced,
      );

  NotificationSettingsDto get() => _dto(
    _container.read(appSettingsProvider),
    synced: _container.read(apiServiceProvider) != null,
  );

  /// Writes [patch] for the account it was asked under: each setter, the
  /// server mirror and the answer go through that account's
  /// [AccountScope.require], so a switch while one setting persists stops
  /// the rest (and the mirror) instead of writing them for the next account.
  Future<NotificationSettingsDto> set(NotificationSettingsPatch patch) async {
    final account = AccountScope.capture(_container);
    final n = _notifier;
    Future<void> write<T>(T? value, Future<void> Function(T) setter) async {
      if (value == null) return;
      account.require('a notification setting is written');
      await setter(value);
    }

    await write(patch.enabled, n.setNotificationsEnabled);
    await write(patch.sound, n.setNotificationSound);
    await write(patch.soundAlways, n.setNotificationSoundAlways);
    await write(patch.inAppBanner, n.setNotificationInAppBanner);
    await write(patch.system, n.setNotificationSystem);
    await write(patch.answers, n.setNotificationChatEnabled);
    await write(patch.channels, n.setNotificationChannelEnabled);
    await write(patch.mentionsOnly, n.setNotificationChannelMentionsOnly);
    // Local persistence went through; the server only mirrors three of them,
    // with the API of the account they were written for.
    account.require('the notification settings are mirrored');
    unawaited(
      syncNotificationPrefsToServer(
        _container.read(apiServiceProvider),
        enabled: patch.enabled,
        sound: patch.sound,
        soundAlways: patch.soundAlways,
      ),
    );
    return get();
  }

  /// Core's decision for one notification. The window says what only it
  /// knows: whether the app is in front, and whether its target is on
  /// screen.
  NotificationRoute route(NotificationRouteParams params) {
    final decision = decideNotification(
      settings: _container.read(appSettingsProvider),
      kind: switch (params.kind) {
        NotifyKind.answer => NotificationKind.chatCompletion,
        NotifyKind.channelMessage => NotificationKind.channelMessage,
      },
      foreground: params.foreground,
      viewing: params.viewing,
      alert: params.alert,
      mention: params.mention,
      direct: params.direct,
    );
    return NotificationRoute(
      surface: switch (decision.surface) {
        NotificationSurface.banner => NotifySurface.banner,
        NotificationSurface.system => NotifySurface.system,
        NotificationSurface.silent => NotifySurface.silent,
        NotificationSurface.suppressed => NotifySurface.suppressed,
      },
      cue: decision.cue,
      systemSound: decision.systemSound,
    );
  }
}
