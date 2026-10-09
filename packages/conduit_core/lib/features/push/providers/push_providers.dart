import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/services/push_backend_factory.dart';
import 'package:conduit_core/features/push/services/push_coordinator.dart';
import 'package:conduit_core/features/push/services/push_relay_client.dart';
import 'package:conduit_core/features/push/services/push_settings_store.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/push_platform_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

export 'package:conduit_core/features/push/services/push_backend_factory.dart'
    show pushOpenWebUiFunctionSourceProvider;
export 'package:conduit_core/features/push/services/push_coordinator.dart';

/// The host's push capability: whatever `main` installed as
/// [PushPlatformPort.hostDefault]. Tests override it with a fake.
final pushPlatformPortProvider = Provider<PushPlatformPort>(
  (ref) => PushPlatformPort.hostDefault,
);

/// The push relay, or null in a build without `CONDUIT_PUSH_RELAY_URL`.
final pushRelayClientProvider = Provider<PushRelayClient?>((ref) {
  if (kConduitPushRelayUrl.isEmpty) return null;
  final client = PushRelayClient(baseUrl: kConduitPushRelayUrl);
  ref.onDispose(client.close);
  return client;
});

final pushSettingsStoreProvider = Provider<PushSettingsStore>(
  (ref) => const PushSettingsStore(),
);

final pushBackendFactoryProvider = Provider<PushBackendFactory>(
  (ref) => AppPushBackendFactory(ref),
);

/// The English display strings, used until the host supplies localized ones.
const Map<String, String> kPushDefaultStrings = {
  'fallbackTitle': 'Conduit',
  'fallbackBody': 'New notification',
  'replyTitle': 'New reply',
  'replyFailedTitle': 'Reply failed',
  'replyFailedBody': "The reply couldn't be finished.",
  'channelTitle': 'New message',
  'cronTitle': 'Scheduled task',
  'testTitle': 'Push notifications work',
  'testBody': 'This test notification came from your server.',
};

/// The strings the platform shows a push with when it has no title of its
/// own. The core cannot localize; the host binds this to the app's language.
final pushLocalizedStringsProvider = Provider<Map<String, String>>(
  (ref) => kPushDefaultStrings,
);

/// How this device describes itself to servers.
final class PushDeviceDescription {
  const PushDeviceDescription({required this.label, required this.platform});

  /// Shown to the user's server next to the subscription, e.g. `iOS`.
  final String label;

  /// `ios` or `android`.
  final String platform;

  static PushDeviceDescription current() {
    if (Platform.isIOS) {
      return const PushDeviceDescription(label: 'iOS', platform: 'ios');
    }
    if (Platform.isAndroid) {
      return const PushDeviceDescription(label: 'Android', platform: 'android');
    }
    final os = Platform.operatingSystem;
    return PushDeviceDescription(label: os, platform: os);
  }
}

final pushDeviceDescriptionProvider = Provider<PushDeviceDescription>(
  (ref) => PushDeviceDescription.current(),
);

/// How long the coordinator waits for things. Tests shorten these.
final class PushTimings {
  const PushTimings({
    this.testTimeout = const Duration(seconds: 20),
    this.testPollInterval = const Duration(seconds: 1),
    this.unsubscribeTimeout = const Duration(seconds: 4),
    this.signOutTimeout = const Duration(seconds: 5),
    this.releaseWait = const Duration(seconds: 2),
    this.restartPollInterval = const Duration(seconds: 3),
    this.restartPollTimeout = const Duration(minutes: 2),
    this.fullReconcileInterval = const Duration(hours: 24),
    this.resumeRetryInterval = const Duration(minutes: 1),
    this.relayInfoMaxAge = const Duration(hours: 1),
  });

  /// How long a test push may take to arrive.
  final Duration testTimeout;

  /// How often the platform is asked for decrypted test nonces meanwhile.
  final Duration testPollInterval;

  /// How long removing a subscription from a server may take.
  final Duration unsubscribeTimeout;

  /// How long a sign-out waits for push cleanup before revoking the session.
  final Duration signOutTimeout;

  /// How long a removal waits for a running setup of the same target.
  final Duration releaseWait;
  final Duration restartPollInterval;
  final Duration restartPollTimeout;

  /// How often every target is checked against its server (which also keeps
  /// the server's `seen` fresh).
  final Duration fullReconcileInterval;

  /// The least time between two automatic retries of a target that is not
  /// on.
  final Duration resumeRetryInterval;
  final Duration relayInfoMaxAge;
}

final pushTimingsProvider = Provider<PushTimings>((ref) => const PushTimings());

final pushClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Set once the push coordinator has started. [pushStateIfUsedProvider]
/// watches it, because `ref.exists` does not subscribe: without it, an
/// answer of null computed before the coordinator started would stay.
final pushCoordinatorStartedProvider =
    NotifierProvider<PushCoordinatorStarted, bool>(PushCoordinatorStarted.new);

final class PushCoordinatorStarted extends Notifier<bool> {
  @override
  bool build() => false;

  void markStarted() {
    if (!state) state = true;
  }
}

/// Push's state for UI outside the push settings, such as the Accounts page
/// and the Hermes job editor: null where push was never turned on and the
/// coordinator has not started, so those screens never start push
/// themselves. In the app the coordinator is started shortly after launch,
/// and this follows it from then on, including when it starts after this
/// was first read.
final pushStateIfUsedProvider = Provider<PushState?>((ref) {
  final started = ref.watch(pushCoordinatorStartedProvider);
  if (!started &&
      !ref.exists(pushCoordinatorProvider) &&
      PreferencesStore.getBool(PreferenceKeys.pushEnabled) != true) {
    return null;
  }
  return ref.watch(pushCoordinatorProvider);
});

/// Whether the Notifications page has anything for a user without an Open
/// WebUI account: a saved Hermes connection (its replies and scheduled tasks
/// notify), or push turned on (it can always be turned off there).
final notificationsWithoutAccountProvider = Provider<bool>((ref) {
  if (ref.watch(hermesConnectionsProvider).isNotEmpty) return true;
  return ref.watch(pushStateIfUsedProvider)?.enabled ?? false;
});

/// The Open WebUI account whose live client holds a token, or null.
///
/// Push reaches the active account through that client, which may not be up
/// yet when push first runs after launch; the coordinator retries an account
/// that needed sign-in once its session is.
final pushActiveOpenWebUiSessionProvider = Provider<String?>((ref) {
  final api = ref.watch(apiServiceProvider);
  final token = api?.authToken;
  if (api == null || token == null || token.isEmpty) return null;
  return api.serverConfig.id;
});

/// Every account and connection push covers, in the order the app lists
/// them: every saved Open WebUI account (signed out ones show as needing
/// sign-in), then every saved Hermes connection while Hermes is on.
final pushTargetsProvider = FutureProvider<List<PushTarget>>((ref) async {
  final hermesEnabled = ref.watch(
    hermesConfigProvider.select((config) => config.enabled),
  );
  final connections = ref.watch(hermesConnectionsProvider);
  final accounts = await ref.watch(openWebUiAccountsProvider.future);
  return [
    for (final entry in accounts)
      OpenWebUiPushTarget(
        accountId: entry.id,
        label: _accountLabel(
          entry.summary.email,
          entry.summary.name,
          entry.server.name,
        ),
        hasSession: entry.hasSession,
      ),
    if (hermesEnabled)
      for (final connection in connections)
        HermesPushTarget(
          connectionId: connection.id,
          label: connection.name,
          baseUrl: connection.baseUrl,
          mode: connection.mode,
          desktopProfile: connection.desktopProfile,
          credentialsRevision: connection.documentTrustPrincipalId,
        ),
  ];
});

String _accountLabel(String? email, String? name, String serverName) {
  for (final value in [email, name, serverName]) {
    final text = value?.trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return serverName;
}

/// Runs before Open WebUI sessions are revoked, so the account's
/// subscription can still be removed from its server with its own token.
///
/// Bounded by [PushTimings.signOutTimeout] and never throws: a sign-out must
/// not wait on, or fail because of, push. Cheap when push was never used.
final class PushSignOutHook {
  const PushSignOutHook(this._ref);

  final Ref _ref;

  /// Whether push was ever set up on this device. Without it the hooks
  /// return at once, and callers that must not yield can skip them.
  bool get inUse =>
      PreferencesStore.getBool(PreferenceKeys.pushEnabled) == true ||
      (PreferencesStore.getString(PreferenceKeys.pushTargets)?.isNotEmpty ??
          false);

  /// Before signing out of the Open WebUI account [accountId].
  Future<void> beforeOpenWebUiSignOut(String accountId) =>
      _run(() => _coordinator.releaseOpenWebUiAccounts([accountId]));

  /// Before signing out of everything and clearing the app's data.
  Future<void> beforeFullSignOut() => _run(() => _coordinator.releaseAll());

  /// Before the saved Hermes connection [connectionId] is deleted.
  Future<void> beforeHermesConnectionRemoved(String connectionId) =>
      _run(() => _coordinator.releaseHermesConnection(connectionId));

  PushCoordinator get _coordinator =>
      _ref.read(pushCoordinatorProvider.notifier);

  Future<void> _run(Future<void> Function() body) async {
    if (!inUse) return;
    try {
      await body().timeout(_ref.read(pushTimingsProvider).signOutTimeout);
    } catch (error) {
      DebugLogger.warning(
        'push-sign-out-cleanup-incomplete',
        scope: 'push',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }
}

final pushSignOutHookProvider = Provider<PushSignOutHook>(PushSignOutHook.new);

/// Tells the Hermes plugin that Conduit started a reply in [sessionId] on
/// [connectionId], so it pushes when the reply finishes. Fire and forget.
typedef PushHermesSessionWatch = void Function(
  String connectionId,
  String sessionId,
);

final pushHermesSessionWatchProvider = Provider<PushHermesSessionWatch>((ref) {
  return (connectionId, sessionId) {
    if (PreferencesStore.getBool(PreferenceKeys.pushEnabled) != true) return;
    try {
      ref
          .read(pushCoordinatorProvider.notifier)
          .watchHermesSession(connectionId, sessionId);
    } catch (error) {
      DebugLogger.warning(
        'push-hermes-watch-failed',
        scope: 'push',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  };
});
