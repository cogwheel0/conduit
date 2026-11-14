import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/notification_policy.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:test/test.dart';

/// The gating chain every host shares: what one notification does, by the
/// settings and what the host says about the window.
void main() {
  const on = AppSettings(notificationsEnabled: true);

  NotificationDecision decide(
    AppSettings settings, {
    NotificationKind kind = NotificationKind.chatCompletion,
    bool foreground = false,
    bool viewing = false,
    bool alert = true,
    bool mention = false,
    bool direct = false,
  }) => decideNotification(
    settings: settings,
    kind: kind,
    foreground: foreground,
    viewing: viewing,
    alert: alert,
    mention: mention,
    direct: direct,
  );

  test('the master toggle and the kind toggles come first', () {
    expect(decide(const AppSettings()), NotificationDecision.suppressed);
    expect(
      decide(on.copyWith(notificationChatEnabled: false)),
      NotificationDecision.suppressed,
    );
    expect(
      decide(
        on.copyWith(notificationChannelEnabled: false),
        kind: NotificationKind.channelMessage,
      ),
      NotificationDecision.suppressed,
    );
  });

  test('a failed reply follows the chat toggle, a scheduled task its own, '
      'and a test push never shows', () {
    expect(
      decide(
        on.copyWith(notificationChatEnabled: false),
        kind: NotificationKind.replyFailed,
      ),
      NotificationDecision.suppressed,
    );
    expect(
      decide(on, kind: NotificationKind.replyFailed).surface,
      NotificationSurface.system,
    );
    expect(
      decide(
        on.copyWith(notificationScheduledEnabled: false),
        kind: NotificationKind.scheduledTask,
      ),
      NotificationDecision.suppressed,
    );
    expect(
      decide(on, kind: NotificationKind.scheduledTask).surface,
      NotificationSurface.system,
    );
    expect(
      decide(on, kind: NotificationKind.pushTest),
      NotificationDecision.suppressed,
    );
  });

  test('one surface by lifecycle: a banner in front, a system notification '
      'behind, silent when that surface is off', () {
    expect(decide(on, foreground: true).surface, NotificationSurface.banner);
    expect(decide(on).surface, NotificationSurface.system);
    expect(
      decide(
        on.copyWith(notificationInAppBanner: false),
        foreground: true,
      ).surface,
      NotificationSurface.silent,
    );
    expect(
      decide(on.copyWith(notificationSystem: false)).surface,
      NotificationSurface.silent,
    );
  });

  test('what the user is looking at in front never notifies; behind, it '
      'does', () {
    expect(
      decide(on, foreground: true, viewing: true),
      NotificationDecision.suppressed,
    );
    expect(decide(on, viewing: true).surface, NotificationSurface.system);
  });

  test('sound: the system notification makes its sound, the cue plays for '
      'every alert with Sound Always', () {
    final system = decide(on);
    expect(system.systemSound, isTrue);
    expect(system.cue, isFalse);
    expect(decide(on.copyWith(notificationSound: false)).systemSound, isFalse);
    final always = on.copyWith(notificationSoundAlways: true);
    expect(decide(always, foreground: true).cue, isTrue);
    expect(decide(always, foreground: true).systemSound, isFalse);
    expect(
      decide(always.copyWith(notificationSound: false), foreground: true).cue,
      isFalse,
    );
  });

  test('a channel message counts as unread even when it does not alert', () {
    final muted = decide(
      on,
      kind: NotificationKind.channelMessage,
      alert: false,
    );
    expect(muted.surface, NotificationSurface.suppressed);
    expect(muted.countsUnread, isTrue);
    expect(
      decide(on, kind: NotificationKind.channelMessage).countsUnread,
      isTrue,
    );
    expect(decide(on).countsUnread, isFalse);
  });

  test('mentions only lets mentions and direct messages through', () {
    final mentions = on.copyWith(notificationChannelMentionsOnly: true);
    final plain = decide(mentions, kind: NotificationKind.channelMessage);
    expect(plain.surface, NotificationSurface.suppressed);
    expect(plain.countsUnread, isTrue);
    expect(
      decide(
        mentions,
        kind: NotificationKind.channelMessage,
        mention: true,
      ).surface,
      NotificationSurface.system,
    );
    expect(
      decide(
        mentions,
        kind: NotificationKind.channelMessage,
        direct: true,
      ).surface,
      NotificationSurface.system,
    );
    // Answers are not channel messages.
    expect(decide(mentions).surface, NotificationSurface.system);
  });
}
