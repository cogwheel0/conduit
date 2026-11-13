import 'dart:async';

import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/notification_policy.dart';
import 'package:conduit_core/features/notifications/services/notification_prefs_sync.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

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

  Future<NotificationSettingsDto> set(NotificationSettingsPatch patch) async {
    final n = _notifier;
    if (patch.enabled case final v?) await n.setNotificationsEnabled(v);
    if (patch.sound case final v?) await n.setNotificationSound(v);
    if (patch.soundAlways case final v?) await n.setNotificationSoundAlways(v);
    if (patch.inAppBanner case final v?) await n.setNotificationInAppBanner(v);
    if (patch.system case final v?) await n.setNotificationSystem(v);
    if (patch.answers case final v?) await n.setNotificationChatEnabled(v);
    if (patch.channels case final v?) await n.setNotificationChannelEnabled(v);
    if (patch.mentionsOnly case final v?) {
      await n.setNotificationChannelMentionsOnly(v);
    }
    // Local persistence went through; the server only mirrors three of them.
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
