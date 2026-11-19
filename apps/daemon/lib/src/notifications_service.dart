import 'dart:async';
import 'dart:collection';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/features/notifications/services/notification_event_classifier.dart';
import 'package:conduit_core/features/notifications/services/notification_policy.dart';
import 'package:conduit_core/features/notifications/services/notification_prefs_sync.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/socket_service.dart';
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
///
/// Answers this Mac did not run: like the phone's notification listener,
/// every chat's events on the Open WebUI socket are heard, and the core's
/// classifier picks each answer's last frame (`chat:completion`, done).
/// One the daemon announced itself ([announced], its own turns and those
/// it followed in a chat it holds) is left to `turn.finished`; any other,
/// from another device or a scheduled task's run, goes to the windows as
/// `notifications.answered`, a moment later (the daemon may still be about
/// to announce it).
final class NotificationsService {
  NotificationsService(
    this._container, {
    EventBus? events,
    bool Function(String messageId)? announced,
    Duration answerGrace = const Duration(milliseconds: 1500),
  }) : _events = events,
       _announced = announced,
       _answerGrace = answerGrace {
    if (events != null) {
      _container.listen<AppSettings>(appSettingsProvider, (previous, next) {
        if (previous != null && _dto(previous) == _dto(next)) return;
        events.emit(ConduitEventSpecs.notificationsChanged, null);
      });
      _bindSocket(_container.read(socketServiceProvider));
      _socket = _container.listen<SocketService?>(
        socketServiceProvider,
        (_, next) => _bindSocket(next),
      );
    }
  }

  final ProviderContainer _container;
  final EventBus? _events;
  final bool Function(String messageId)? _announced;
  final Duration _answerGrace;
  ProviderSubscription<SocketService?>? _socket;
  SocketService? _boundSocket;
  SocketEventSubscription? _chatEvents;

  /// Answers heard and waiting out the grace, by dedup key: forgotten when
  /// their socket goes, so the next socket's replay of one is heard again.
  final Map<String, Timer> _waiting = <String, Timer>{};

  /// Answers settled (told, or left to `turn.finished`): a replay of one is
  /// a duplicate.
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  static const _classifier = NotificationEventClassifier();

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

  /// The tail of the local changes: each one's settings are written after
  /// the one before it.
  Future<void> _changes = Future<void>.value();

  /// Per account ([AccountScope.account]: the primary account and its
  /// server; never a user, token, client or session), the tail of the
  /// server mirrors: each one goes after the one before it, in the order
  /// their changes were written, and none ever holds a local change. A
  /// renewed token, a rebuilt client or the user being validated keeps the
  /// queue and its order.
  final Map<Object, Future<void>> _mirrors = {};

  /// Writes [patch] for the account it was asked under: each setter, the
  /// server mirror and the answer go through that account's
  /// [AccountScope.require], so a switch while one setting persists stops
  /// the rest (and the mirror) instead of writing them for the next account.
  ///
  /// Local changes run one at a time and are answered once their settings
  /// are written. Each then queues its server mirror behind that account's
  /// earlier ones (one queue per account, whichever client serves it): the
  /// server gets the changes in the order this Mac wrote them, so it ends up
  /// with the last one, and a slow server never holds the next change.
  Future<NotificationSettingsDto> set(NotificationSettingsPatch patch) {
    final account = AccountScope.capture(_container);
    final written = Completer<NotificationSettingsDto>();
    final change = _changes.then((_) async {
      try {
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
        // Local persistence went through; the server only mirrors three of
        // them, with the API of the account they were written for.
        account.require('the notification settings are answered');
        written.complete(get());
        _mirror(account, patch);
      } on Object catch (error, stack) {
        written.completeError(error, stack);
      }
    });
    _changes = change.then<void>((_) {}, onError: (Object _) {});
    return written.future;
  }

  /// Queues [patch]'s server mirror on [account]'s queue, behind its
  /// earlier ones. When its turn comes it goes only while the same account
  /// is in charge ([AccountScope.sameAccountOnceKnown]: a renewed session
  /// of it still is, once its user is known again; another user or server
  /// is not, and its pending mirrors are dropped), with the API client
  /// serving it then, read under that check. Never throws: a failed mirror
  /// only loses the parity.
  void _mirror(AccountScope account, NotificationSettingsPatch patch) {
    if (patch.enabled == null &&
        patch.sound == null &&
        patch.soundAlways == null) {
      return;
    }
    final key = account.account;
    final tail = (_mirrors[key] ?? Future<void>.value()).then((_) async {
      if (!await account.sameAccountOnceKnown()) return;
      // Asked again with nothing awaited before the client is read: another
      // account can take charge as the wait ends.
      if (!account.isSameAccount) return;
      final api = _container.read(apiServiceProvider);
      await syncNotificationPrefsToServer(
        api,
        enabled: patch.enabled,
        sound: patch.sound,
        soundAlways: patch.soundAlways,
      );
    });
    _mirrors[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_mirrors[key], tail)) _mirrors.remove(key);
      }),
    );
  }

  void dispose() {
    _socket?.close();
    _socket = null;
    _chatEvents?.dispose();
    _chatEvents = null;
    for (final timer in _waiting.values) {
      timer.cancel();
    }
    _waiting.clear();
  }

  void _bindSocket(SocketService? socket) {
    if (identical(socket, _boundSocket)) return;
    _boundSocket = socket;
    _chatEvents?.dispose();
    _chatEvents = null;
    // What the last socket heard belongs to the account it served.
    for (final timer in _waiting.values) {
      timer.cancel();
    }
    _waiting.clear();
    if (socket == null) return;
    // Every chat's events, open or not, as the phone's listener hears them.
    _chatEvents = socket.addChatEventHandler(
      requireFocus: false,
      handler: (event, _) => _onChatEvent(event),
    );
  }

  /// The notification scope of the account the socket belongs to: the
  /// active Open WebUI account. Null before an account settles, when
  /// nothing can be attributed to one.
  String? get _notificationScope {
    final accountId = _container.read(settledActiveAccountIdProvider);
    if (accountId == null || accountId.isEmpty) return null;
    return NotificationScope.openWebUi(accountId).value;
  }

  void _onChatEvent(Map<String, dynamic> event) {
    try {
      final me = _container.read(currentUserProvider2)?.id ?? '';
      final scope = _notificationScope;
      if (scope == null) return;
      final notification = _classifier.classifyChatEvent(
        event,
        currentUserId: me,
        scope: scope,
      );
      if (notification == null) return;
      final key = notification.dedupKey;
      if (_seen.contains(key) || _waiting.containsKey(key)) return;
      final messageId = event['message_id'] is String
          ? event['message_id'] as String
          : '';
      final notice = AnswerNotice(
        chatId: notification.sourceId,
        messageId: messageId,
        title: notification.title,
      );
      // The notice carries the account it was heard under: told only while
      // that account (on the same socket) is still the one in charge, as a
      // click opens its chat in whichever account is.
      final heardOn = _boundSocket;
      _waiting[key] = Timer(_answerGrace, () {
        _waiting.remove(key);
        if (!identical(_boundSocket, heardOn) || _notificationScope != scope) {
          return;
        }
        _settled(key);
        if (messageId.isNotEmpty && (_announced?.call(messageId) ?? false)) {
          return;
        }
        _events?.emit(ConduitEventSpecs.notificationsAnswered, notice);
      });
    } on Object {
      // A malformed envelope is no answer: nothing to say.
    }
  }

  /// [key]'s answer is settled: a replay of it says nothing again.
  void _settled(String key) {
    _seen.add(key);
    if (_seen.length > 256) _seen.remove(_seen.first);
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
