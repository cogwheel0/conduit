import 'dart:async';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/error/api_error.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notifications/models/notification_target.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';

part 'notification_target_providers.g.dart';

/// Thrown when the signed-in account may not manage webhook destinations: the
/// server has them off, or the account lacks the `features.webhooks`
/// permission. Nothing was sent.
final class NotificationTargetsUnavailableException implements Exception {
  const NotificationTargetsUnavailableException();

  @override
  String toString() =>
      'NotificationTargetsUnavailableException: webhook destinations are not '
      'available for this account';
}

/// Thrown when the account an editor or list was opened for is no longer the
/// signed-in one. Nothing was sent, so the form can keep its input.
final class NotificationTargetsOwnerChangedException extends StateError {
  NotificationTargetsOwnerChangedException()
    : super('The account changed since this destination was opened');
}

/// The account an editor, confirmation or list was opened for.
///
/// The notifier outlives account switches and the [ApiService] can stay the
/// same across them, so holding either says nothing about whose destinations a
/// later Save, Test or Delete would change. Capture the owner synchronously
/// when the surface opens, before any await, and pass it to every operation.
/// An operation is refused before any request once the API, auth session or
/// server no longer match, and its request is bound to the captured
/// [ApiAuthSnapshot] so a credential change that lands later still cannot
/// redirect it.
@immutable
final class NotificationTargetsOwner {
  const NotificationTargetsOwner._(this._api, this._auth, this._ownership);

  final ApiService _api;
  final ApiAuthSnapshot _auth;
  final OpenWebUiCacheOwnershipSnapshot _ownership;
}

/// Destinations and the catalog of events they can subscribe to.
@immutable
final class NotificationTargetsData {
  const NotificationTargetsData({
    this.targets = const <NotificationTarget>[],
    this.events = const <NotificationEvent>[],
    this.stale = false,
  });

  final List<NotificationTarget> targets;

  /// What the server says a destination can subscribe to. Empty when the
  /// catalog could not be read; destinations still list and edit, and an
  /// editor shows the events a destination already holds.
  final List<NotificationEvent> events;

  /// True when a change went through but reading the list back failed, so
  /// [targets] may not show it yet.
  final bool stale;
}

/// Whether [user] may manage webhook destinations on [serverId].
///
/// Open WebUI offers them only when the server's `enable_user_webhooks` is on
/// and the account is an admin or holds `features.webhooks`. Unlike memories, a
/// missing permission means denied. [config] counts only when it was fetched
/// from [serverId].
bool notificationTargetsPermitted({
  required BackendConfig? config,
  required String serverId,
  required User? user,
  required Map<String, dynamic> permissions,
}) {
  if (config == null ||
      config.serverId != serverId ||
      config.enableUserWebhooks != true) {
    return false;
  }
  if (user?.role == 'admin') return true;
  final features = permissions['features'];
  return features is Map && features['webhooks'] == true;
}

/// Whether the signed-in account can use webhook destinations right now, for
/// surfaces deciding whether to show them. False while the inputs load.
///
/// This only reads [userPermissionsProvider] and [backendConfigProvider]. The
/// operations recheck the same rule themselves.
final notificationTargetsAvailableProvider = Provider<bool>((ref) {
  final api = ref.watch(apiServiceProvider);
  ref.watch(openWebUiAuthSessionEpochProvider);
  final user = ref.watch(currentUserProvider2);
  final config = ref.watch(backendConfigProvider).asData?.value;
  final permissions =
      ref.watch(userPermissionsProvider).asData?.value ??
      (user?.role == 'admin' ? const <String, dynamic>{} : null);
  if (api == null || permissions == null) return false;
  return notificationTargetsPermitted(
    config: config,
    serverId: api.serverConfig.id,
    user: user,
    permissions: permissions,
  );
});

/// The server's own explanation for a refused request, such as "Webhook URL is
/// required", or null when it gave none. Never the request body or URL.
String? notificationTargetErrorDetail(Object error) {
  if (error is! DioException) return null;
  final apiError = error.error;
  if (apiError is! ApiError) return null;
  final detail = apiError.details?.message ?? apiError.message;
  return detail == null || detail.isEmpty ? null : detail;
}

// A refused or failed load is shown as it is. Riverpod's default would send the
// same authenticated request again, up to ten times, behind the user's back;
// the user's own refresh is the retry.
Duration? _doNotRetryTargetsLoad(int retryCount, Object error) => null;

/// Webhook destinations of the signed-in account, kept on the server.
///
/// Management is online only. Every operation, loads included, is admitted
/// for a [NotificationTargetsOwner] and rechecks that account's capability
/// before it sends. The destination URL never enters state: a destination
/// carries only the server's masked form, and a URL is sent only when the
/// caller passes a replacement.
@Riverpod(keepAlive: true, retry: _doNotRetryTargetsLoad)
class NotificationTargets extends _$NotificationTargets {
  int _loadGeneration = 0;

  @override
  Future<NotificationTargetsData> build() async {
    ref.watch(activeServerProvider.select((s) => s.asData?.value?.id));
    // A same-server account switch keeps the same ApiService, so the auth
    // session is what retires one account's destinations for the next.
    ref.watch(openWebUiAuthSessionEpochProvider);
    ref.watch(notificationTargetsAvailableProvider);
    final apiAlive = ref.watch(apiServiceProvider.select((a) => a != null));
    final owner = apiAlive ? captureOwner() : null;
    if (owner == null) return const NotificationTargetsData();

    final data = await _load(owner);
    if (!_isCurrent(owner)) return const NotificationTargetsData();
    return data;
  }

  /// The account that is signed in now, for a surface to hold until it acts.
  /// Null when no signed-in account can own destinations at the moment.
  NotificationTargetsOwner? captureOwner() {
    final api = ref.read(apiServiceProvider);
    if (api == null) return null;
    final ownership = captureOpenWebUiCacheOwnership(ref, api: api);
    if (ownership == null) return null;
    return NotificationTargetsOwner._(
      api,
      api.captureAuthSnapshot(),
      ownership,
    );
  }

  /// Whether [owner] is still the signed-in account.
  bool isCurrentOwner(NotificationTargetsOwner owner) => _isCurrent(owner);

  /// Reloads the list for [owner]. A result that arrives after the account has
  /// changed is dropped.
  Future<void> refresh({required NotificationTargetsOwner owner}) async {
    if (!_isCurrent(owner)) return;
    if (!state.hasValue) state = const AsyncLoading<NotificationTargetsData>();
    await _reload(owner);
  }

  Future<NotificationTarget> create({
    required String url,
    required bool enabled,
    required List<String> events,
    required String delivery,
    String? id,
    required NotificationTargetsOwner owner,
  }) async {
    final operation = await _admit(owner);
    final created = await operation._api.createNotificationTarget(
      url: url,
      enabled: enabled,
      events: events,
      delivery: delivery,
      id: id,
      authSnapshot: operation._auth,
    );
    await _reload(owner);
    return created;
  }

  /// Updates a destination. Only the arguments passed are sent, and
  /// [replacementUrl] is the one way a URL goes out, so an edit that leaves
  /// the destination alone never touches the secret the server holds.
  Future<NotificationTarget> updateTarget(
    String targetId, {
    bool? enabled,
    List<String>? events,
    String? delivery,
    String? replacementUrl,
    required NotificationTargetsOwner owner,
  }) async {
    final operation = await _admit(owner);
    final updated = await operation._api.updateNotificationTarget(
      targetId,
      enabled: enabled,
      events: events,
      delivery: delivery,
      replacementUrl: replacementUrl,
      authSnapshot: operation._auth,
    );
    await _reload(owner);
    return updated;
  }

  Future<NotificationTarget> makeDefault(
    String targetId, {
    required NotificationTargetsOwner owner,
  }) async {
    final operation = await _admit(owner);
    final target = await operation._api.setDefaultNotificationTarget(
      targetId,
      authSnapshot: operation._auth,
    );
    await _reload(owner);
    return target;
  }

  Future<void> remove(
    String targetId, {
    required NotificationTargetsOwner owner,
  }) async {
    final operation = await _admit(owner);
    await operation._api.deleteNotificationTarget(
      targetId,
      authSnapshot: operation._auth,
    );
    await _reload(owner);
  }

  /// Asks the server to deliver one real test notification. Call this only
  /// from an explicit user action: the server contacts the webhook.
  Future<void> sendTest(
    String targetId, {
    required NotificationTargetsOwner owner,
  }) async {
    final operation = await _admit(owner);
    await operation._api.testNotificationTarget(
      targetId,
      authSnapshot: operation._auth,
    );
  }

  bool _isCurrent(NotificationTargetsOwner owner) =>
      ref.mounted && openWebUiCacheOwnershipIsCurrent(ref, owner._ownership);

  /// Admits one operation for [owner]: the account must still be the signed-in
  /// one, and still be allowed webhook destinations, both checked after the
  /// permission lookup so a change during it is caught.
  Future<NotificationTargetsOwner> _admit(
    NotificationTargetsOwner owner,
  ) async {
    if (!_isCurrent(owner)) throw NotificationTargetsOwnerChangedException();

    // Read through the shared providers rather than fetching again. A failed
    // read is a denial: webhooks default to off, not on.
    final permissions = await _settled(userPermissionsProvider);
    final config = await _settled(backendConfigProvider);
    if (!_isCurrent(owner)) throw NotificationTargetsOwnerChangedException();
    if (permissions == null ||
        config == null ||
        !notificationTargetsPermitted(
          config: config.value,
          serverId: owner._ownership.serverId,
          user: ref.read(currentUserProvider2),
          permissions: permissions.value,
        )) {
      throw const NotificationTargetsUnavailableException();
    }
    return owner;
  }

  /// The first settled value of [provider], or null when it failed or this
  /// notifier rebuilt first.
  ///
  /// Awaiting `provider.future` instead can wait forever: a build that an
  /// account switch replaced may never complete, and a Save would spin with no
  /// way out. This notifier rebuilds on every session change, and that also
  /// drops listeners made through its ref, so the rebuild itself ends the wait.
  /// The caller's ownership check then decides what it means.
  Future<({T value})?> _settled<T>(
    ProviderListenable<AsyncValue<T>> provider,
  ) async {
    final settled = Completer<({T value})?>();
    final subscription = ref.listen<AsyncValue<T>>(
      provider,
      fireImmediately: true,
      (_, next) {
        if (next.isLoading || settled.isCompleted) return;
        settled.complete(next.hasError ? null : (value: next.requireValue));
      },
    );
    final stopWatchingRebuild = ref.onDispose(() {
      if (!settled.isCompleted) settled.complete(null);
    });
    try {
      return await settled.future;
    } finally {
      subscription.close();
      stopWatchingRebuild();
    }
  }

  Future<NotificationTargetsData> _load(NotificationTargetsOwner owner) async {
    final operation = await _admit(owner);
    // The catalog only labels events. Listing destinations does not wait on
    // it, and a failure to read it leaves the list usable.
    final catalog = operation._api
        .getNotificationEvents(authSnapshot: operation._auth)
        .then<List<NotificationEvent>>(
          (events) => events,
          onError: (Object _) => const <NotificationEvent>[],
        );
    final targets = await operation._api.getNotificationTargets(
      authSnapshot: operation._auth,
    );
    return NotificationTargetsData(targets: targets, events: await catalog);
  }

  /// Replaces the list with the server's, unless a newer load started or the
  /// account changed. A failure keeps the list that was showing, marked stale.
  Future<void> _reload(NotificationTargetsOwner owner) async {
    final generation = ++_loadGeneration;
    try {
      final data = await _load(owner);
      if (generation != _loadGeneration || !_isCurrent(owner)) return;
      state = AsyncData(data);
    } catch (error, stackTrace) {
      if (generation != _loadGeneration || !_isCurrent(owner)) return;
      final shown = state.asData?.value;
      state = shown == null
          ? AsyncError<NotificationTargetsData>(error, stackTrace)
          : AsyncData(
              NotificationTargetsData(
                targets: shown.targets,
                events: shown.events,
                stale: true,
              ),
            );
    }
  }
}
