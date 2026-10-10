import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind, kChatStorageKindMetadataKey;
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/features/notifications/services/cp1_notification_mapper.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../core/utils/current_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../hermes/widgets/hermes_session_tile.dart';
import '../../navigation/providers/conversation_selection_provider.dart';
import '../../profile/widgets/account_actions.dart' as accounts;
import 'local_notification_service.dart';

part 'notification_tap_router.g.dart';

/// What opening a tapped notification needs from the screen: asking,
/// telling, and going places. [NotificationTapRouter] decides what to do;
/// this does it.
abstract interface class NotificationTapNavigator {
  /// Asks whether to switch accounts although that stops a reply still being
  /// written, as the Accounts page asks.
  Future<bool> confirmSwitchStopsReply();

  /// Opens sign-in for the active account, which a switch left signed out.
  void openSignIn();

  /// Makes [connectionId] the Hermes connection in use, with Hermes on, as
  /// the Accounts page does. Returns whether it is.
  Future<bool> useHermesConnection(String connectionId);

  /// Says the notification's account or connection is no longer here.
  void showTargetUnavailable();

  /// Says the notification could not be opened.
  void showError();

  /// Opens chat [chatId] of the active Open WebUI account.
  Future<void> openOpenWebUiChat(String chatId);

  /// Opens channel [channelId] of the active Open WebUI account.
  void openChannel(String channelId);

  /// Opens session [sessionId] of the Hermes connection [connectionId], which
  /// was just put in use; nothing, when another connection took its place
  /// meanwhile. [title] is the notification's, for when the session list
  /// doesn't say.
  Future<void> openHermesSession(
    String sessionId, {
    required String connectionId,
    required String title,
  });

  /// Opens the Hermes scheduled tasks of the connection in use.
  void openHermesJobs();

  /// Opens the on-device conversation [conversationId], or says it is gone.
  Future<void> openDirectConversation(
    String conversationId, {
    required String title,
  });
}

/// Opens what a tapped notification points at, in the account or connection
/// that posted it.
///
/// A notification of an Open WebUI account that isn't active switches to it
/// first, asking and signing in exactly as switching from the Accounts page
/// does. A Hermes one switches connection first. A Direct one opens the
/// on-device conversation. One whose account or connection was removed says
/// so and stays where the app is.
class NotificationTapRouter {
  NotificationTapRouter(
    this._ref,
    this._navigator, {
    Duration settleTimeout = const Duration(seconds: 5),
  }) : _settleTimeout = settleTimeout;

  final Ref _ref;
  final NotificationTapNavigator _navigator;
  final Duration _settleTimeout;

  /// Opens a tapped system notification.
  Future<void> openTap(NotificationTap tap) => _open(
    kind: tap.kind,
    scope: tap.scope,
    sourceId: tap.sourceId,
    title: '',
  );

  /// Opens [notification], as the "View" action of its in-app banner does.
  Future<void> openNotification(AppNotification notification) => _open(
    kind: notification.kind,
    scope: notification.scope,
    sourceId: notification.sourceId,
    title: notification.title,
  );

  /// Opens a tapped push: the decrypted `cp/1` [payload] of the subscription
  /// for [scope]. Returns false, opening nothing, when it isn't a valid
  /// payload.
  Future<bool> openCp1(Object? payload, {required String scope}) async {
    final notification = appNotificationFromCp1(payload, scope: scope);
    if (notification == null) return false;
    await openNotification(notification);
    return true;
  }

  Future<void> _open({
    required NotificationKind kind,
    required String? scope,
    required String sourceId,
    required String title,
  }) async {
    // Fire-and-forget from tap streams / cold launch — never let a navigation
    // failure surface as an uncaught async error.
    try {
      if (kind == NotificationKind.pushTest) return;
      if (scope == null) {
        // Posted before notifications knew their account: the active one.
        await _openInOpenWebUi(kind, sourceId);
        return;
      }
      switch (NotificationScope.tryParse(scope)) {
        case OpenWebUiNotificationScope(:final accountId):
          if (!await _enterOpenWebUiAccount(accountId)) return;
          await _openInOpenWebUi(kind, sourceId);
        case HermesNotificationScope(:final connectionId):
          if (!await _enterHermesConnection(connectionId)) return;
          if (kind == NotificationKind.scheduledTask) {
            _navigator.openHermesJobs();
          } else if (_isReply(kind)) {
            await _navigator.openHermesSession(
              sourceId,
              connectionId: connectionId,
              title: title,
            );
          }
        case DirectNotificationScope():
          if (_isReply(kind)) {
            await _navigator.openDirectConversation(sourceId, title: title);
          }
        case null:
          return;
      }
    } catch (e, st) {
      DebugLogger.error(
        'notification deep-link failed',
        error: e,
        stackTrace: st,
        scope: 'notifications/center',
      );
    }
  }

  static bool _isReply(NotificationKind kind) =>
      kind == NotificationKind.chatCompletion ||
      kind == NotificationKind.replyFailed;

  Future<void> _openInOpenWebUi(NotificationKind kind, String sourceId) async {
    if (kind == NotificationKind.channelMessage) {
      _navigator.openChannel(sourceId);
    } else if (_isReply(kind)) {
      await _navigator.openOpenWebUiChat(sourceId);
    }
  }

  /// Makes [accountId] active and signed in. Returns whether it is, having
  /// said why not when it was removed or the switch failed.
  Future<bool> _enterOpenWebUiAccount(String accountId) async {
    final entries = await _ref.read(openWebUiAccountsProvider.future);
    if (!entries.any((entry) => entry.id == accountId)) {
      _navigator.showTargetUnavailable();
      return false;
    }
    final OpenWebUiAccountChangeResult? result;
    try {
      result = await accounts.switchOpenWebUiAccountConfirming(
        _ref.read(openWebUiAccountsControllerProvider),
        accountId,
        confirmStopReply: _navigator.confirmSwitchStopsReply,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'account-switch-failed',
        scope: 'notifications/center',
        error: error,
        stackTrace: stackTrace,
      );
      _navigator.showError();
      return false;
    }
    switch (result) {
      case null || OpenWebUiAccountChangeResult.blockedByActiveReply:
        return false;
      case OpenWebUiAccountChangeResult.needsSignIn:
        _navigator.openSignIn();
        return false;
      case OpenWebUiAccountChangeResult.done ||
          OpenWebUiAccountChangeResult.alreadyActive:
        return _awaitSettledAccount(accountId);
    }
  }

  /// Waits for the switch to [accountId] to settle, so the chat opens from
  /// that account's storage. False when it doesn't in time.
  Future<bool> _awaitSettledAccount(String accountId) async {
    final deadline = DateTime.now().add(_settleTimeout);
    while (_ref.read(settledActiveAccountIdProvider) != accountId) {
      if (!_ref.mounted || DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return true;
  }

  /// Makes [connectionId] the Hermes connection in use, with Hermes on.
  Future<bool> _enterHermesConnection(String connectionId) async {
    final connections = _ref.read(hermesConnectionsProvider);
    if (!connections.any((connection) => connection.id == connectionId)) {
      _navigator.showTargetUnavailable();
      return false;
    }
    if (_ref.read(hermesActiveConnectionIdProvider) == connectionId &&
        _ref.read(hermesEnabledProvider)) {
      return true;
    }
    return _navigator.useHermesConnection(connectionId);
  }
}

/// The app's [NotificationTapNavigator], acting on the root navigator.
class AppNotificationTapNavigator implements NotificationTapNavigator {
  AppNotificationTapNavigator(this._ref);

  final Ref _ref;

  /// The root navigator's context, once it is mounted. A cold-launch tap can
  /// arrive before it is.
  Future<BuildContext?> _context() async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final context = NavigationService.context;
      if (context != null && context.mounted) return context;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  void _showMessage(String message) {
    final context = NavigationService.context;
    if (context == null || !context.mounted) return;
    UiUtils.showMessage(context, message);
  }

  @override
  Future<bool> confirmSwitchStopsReply() async {
    final context = await _context();
    if (context == null || !context.mounted) return false;
    return accounts.confirmSwitchStopsReply(context);
  }

  @override
  void openSignIn() =>
      accounts.openActiveAccountSignIn(NavigationService.router);

  @override
  Future<bool> useHermesConnection(String connectionId) async {
    final context = await _context();
    if (context == null || !context.mounted) return false;
    return accounts.useHermesConnectionReading(
      context,
      _ref.read,
      connectionId,
    );
  }

  @override
  void showTargetUnavailable() =>
      _showMessage(currentAppLocalizations().notificationTargetUnavailable);

  @override
  void showError() => _showMessage(currentAppLocalizations().errorMessage);

  @override
  Future<void> openOpenWebUiChat(String chatId) async {
    // The chat list's selection flow: it waits for the account's storage,
    // which a switch may still be settling, loads the chat (from the server
    // when there is no copy here) and makes it the active conversation,
    // clearing what belonged to the one it replaces.
    final now = DateTime.now();
    final result = await _ref
        .read(conversationSelectionProvider.notifier)
        .select(
          Conversation(
            id: chatId,
            title: '',
            createdAt: now,
            updatedAt: now,
            metadata: {
              kChatStorageKindMetadataKey: ChatStorageKind.openWebUi.name,
            },
          ),
        );
    switch (result.disposition) {
      case ConversationSelectionDisposition.committed:
        await NavigationService.navigateToChat();
      case ConversationSelectionDisposition.canceled:
        // Another selection or account took over.
        break;
      case ConversationSelectionDisposition.failed:
        showError();
    }
  }

  @override
  void openChannel(String channelId) =>
      NavigationService.navigateToChannel(channelId);

  @override
  Future<void> openHermesSession(
    String sessionId, {
    required String connectionId,
    required String title,
  }) async {
    final context = await _context();
    if (context == null || !context.mounted) return;
    // A switch rebuilds the service; a cold start may still be loading it.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_ref.read(hermesApiServiceProvider) == null) {
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!_hermesConnectionInUse(connectionId)) return;
    var sessionTitle = title;
    try {
      final sessions = await _ref
          .read(hermesSessionsProvider.future)
          .timeout(const Duration(seconds: 3));
      for (final session in sessions) {
        if (session.id == sessionId) {
          sessionTitle = session.title;
          break;
        }
      }
    } catch (_) {
      // The list only names the session; it opens without it.
    }
    // Opening reads whichever connection is in use. Another tap, or the
    // user, may have switched while the list loaded, and the session id
    // means nothing there.
    if (!context.mounted || !_hermesConnectionInUse(connectionId)) return;
    await openHermesSessionReading(
      context,
      _ref.read,
      HermesSessionSummary(id: sessionId, title: sessionTitle),
    );
  }

  /// Whether [connectionId] is the Hermes connection in use, its service
  /// built for it.
  bool _hermesConnectionInUse(String connectionId) =>
      _ref.read(hermesActiveConnectionIdProvider) == connectionId &&
      _ref.read(hermesApiServiceProvider)?.config.connectionId == connectionId;

  @override
  void openHermesJobs() =>
      unawaited(NavigationService.router.pushNamed<void>(RouteNames.hermesJobs));

  @override
  Future<void> openDirectConversation(
    String conversationId, {
    required String title,
  }) async {
    final active = _ref.read(activeConversationProvider);
    if (active?.id == conversationId) {
      // Still open, or a temporary chat that only lives while it is.
      await NavigationService.navigateToChat();
      return;
    }
    final now = DateTime.now();
    final result = await _ref
        .read(conversationSelectionProvider.notifier)
        .select(
          Conversation(
            id: conversationId,
            title: title,
            createdAt: now,
            updatedAt: now,
            metadata: {
              kChatStorageKindMetadataKey: ChatStorageKind.directLocal.name,
            },
          ),
        );
    switch (result.disposition) {
      case ConversationSelectionDisposition.committed:
        await NavigationService.navigateToChat();
      case ConversationSelectionDisposition.canceled:
        // Not found, or another selection took over.
        if (_ref.read(activeConversationProvider)?.id != conversationId) {
          showTargetUnavailable();
        }
      case ConversationSelectionDisposition.failed:
        showTargetUnavailable();
    }
  }
}

/// The app's notification tap router. keepAlive: taps arrive any time.
@Riverpod(keepAlive: true)
NotificationTapRouter notificationTapRouter(Ref ref) =>
    NotificationTapRouter(ref, AppNotificationTapNavigator(ref));
