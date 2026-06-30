import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/backend_config.dart';
import '../../../core/models/user.dart';
import '../../../core/providers/app_providers.dart'
    show apiServiceProvider, backendConfigProvider, currentUserProvider;
import '../../../core/providers/storage_providers.dart'
    show secureStorageProvider;
import '../../../core/services/api_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/debug_logger.dart';
import 'local_notification_service.dart';
import 'remote_push_build_config.dart';
import 'remote_push_models.dart';
import 'remote_push_proxy_client.dart';
import 'remote_push_subscription_store.dart';
import 'remote_push_token_provider.dart';

typedef RemotePushProxyClientFactory =
    RemotePushProxyClient Function(Uri baseUri);

class RemotePushService {
  RemotePushService({
    required Ref ref,
    required RemotePushBuildConfig config,
    required RemotePushSubscriptionStore store,
    required RemotePushTokenProvider tokenProvider,
    RemotePushProxyClientFactory? proxyClientFactory,
  }) : _ref = ref,
       _config = config,
       _store = store,
       _tokenProvider = tokenProvider,
       _proxyClientFactory =
           proxyClientFactory ??
           ((baseUri) => RemotePushProxyClient(baseUri: baseUri));

  final Ref _ref;
  final RemotePushBuildConfig _config;
  final RemotePushSubscriptionStore _store;
  final RemotePushTokenProvider _tokenProvider;
  final RemotePushProxyClientFactory _proxyClientFactory;

  final StreamController<NotificationTap> _taps =
      StreamController<NotificationTap>.broadcast();

  StreamSubscription<NotificationTap>? _tapSub;
  StreamSubscription<RemotePushDeviceToken>? _tokenRefreshSub;
  Future<bool>? _starting;
  bool _started = false;

  Stream<NotificationTap> get taps => _taps.stream;

  bool get isBuildConfigured => _config.isConfigured;

  Future<bool> start() {
    if (_started) return Future<bool>.value(true);
    if (!_config.isSupportedPlatform) return Future<bool>.value(false);
    if (!_config.isConfigured) return Future<bool>.value(false);
    return _starting ??= _doStart();
  }

  Future<bool> _doStart() async {
    try {
      final initialized = await _tokenProvider.initialize();
      if (!initialized) return false;
      _tapSub ??= _tokenProvider.taps.listen((tap) {
        if (!_taps.isClosed) {
          _taps.add(tap);
        }
      });
      _tokenRefreshSub ??= _tokenProvider.tokenRefreshes.listen((_) {
        unawaited(syncForCurrentSettings());
      });
      _started = true;
      return true;
    } finally {
      _starting = null;
    }
  }

  Future<NotificationTap?> launchTap() async {
    if (!await start()) return null;
    return _tokenProvider.launchTap();
  }

  Future<RemotePushSyncResult> syncForCurrentSettings({
    bool requestPermission = false,
  }) async {
    if (!_config.isSupportedPlatform) {
      return const RemotePushSyncResult(
        RemotePushSyncStatus.unsupportedPlatform,
      );
    }
    if (!_config.isConfigured) {
      return const RemotePushSyncResult(
        RemotePushSyncStatus.buildNotConfigured,
      );
    }

    final settings = _ref.read(appSettingsProvider);
    if (!settings.notificationsEnabled || !settings.notificationSystem) {
      await disableForActiveServer(removeServerWebhook: true);
      return const RemotePushSyncResult(
        RemotePushSyncStatus.disabledByPreference,
      );
    }
    return enableForActiveServer(requestPermission: requestPermission);
  }

  Future<RemotePushSyncResult> enableForActiveServer({
    bool requestPermission = false,
  }) async {
    if (!_config.isSupportedPlatform) {
      return const RemotePushSyncResult(
        RemotePushSyncStatus.unsupportedPlatform,
      );
    }
    final proxyBaseUri = _config.proxyBaseUri;
    if (!_config.isConfigured || proxyBaseUri == null) {
      return const RemotePushSyncResult(
        RemotePushSyncStatus.buildNotConfigured,
      );
    }
    if (!await start()) {
      return const RemotePushSyncResult(
        RemotePushSyncStatus.buildNotConfigured,
      );
    }

    if (requestPermission && !await _tokenProvider.requestPermission()) {
      return const RemotePushSyncResult(RemotePushSyncStatus.permissionDenied);
    }

    final api = _ref.read(apiServiceProvider);
    final user = await _currentUser();
    if (api == null || user == null || user.id.isEmpty) {
      return const RemotePushSyncResult(RemotePushSyncStatus.missingSession);
    }

    final backendConfig = await _freshBackendConfig();
    if (backendConfig?.enableUserWebhooks != true) {
      await disableForActiveServer(removeServerWebhook: true);
      return const RemotePushSyncResult(
        RemotePushSyncStatus.serverUserWebhooksDisabled,
      );
    }

    final deviceToken = await _tokenProvider.getDeviceToken();
    if (deviceToken == null) {
      return const RemotePushSyncResult(RemotePushSyncStatus.tokenUnavailable);
    }

    final previous = await _store.read(api.serverConfig.id);
    final client = _proxyClientFactory(proxyBaseUri);

    try {
      final installationId = await _store.getOrCreateInstallationId();
      final registration = await client.register(
        serverId: api.serverConfig.id,
        serverUrl: api.serverConfig.url,
        userId: user.id,
        installationId: installationId,
        deviceToken: deviceToken,
      );
      final subscription = RemotePushSubscription(
        serverId: api.serverConfig.id,
        userId: user.id,
        installationId: installationId,
        subscriptionId: registration.subscriptionId,
        webhookUrl: registration.webhookUrl,
        proxyBaseUrl: proxyBaseUri.toString(),
        platform: deviceToken.platform,
        tokenType: deviceToken.tokenType,
        updatedAt: DateTime.now(),
      );

      try {
        await api.updateUserNotificationWebhook(
          webhookUrl: subscription.webhookUrl,
          expectedCurrentWebhookUrl: previous?.webhookUrl,
        );
      } on UserNotificationWebhookConflictException catch (e) {
        await _unregisterBestEffort(client, subscription);
        return RemotePushSyncResult(
          RemotePushSyncStatus.existingWebhookConflict,
          error: e,
        );
      } catch (e) {
        await _unregisterBestEffort(client, subscription);
        rethrow;
      }

      await _store.write(subscription);
      if (previous != null &&
          previous.subscriptionId != subscription.subscriptionId) {
        await _unregisterSubscriptionBestEffort(previous);
      }
      return const RemotePushSyncResult(RemotePushSyncStatus.registered);
    } catch (e, st) {
      DebugLogger.error(
        'remote push sync failed',
        error: e,
        stackTrace: st,
        scope: 'notifications/push',
      );
      return RemotePushSyncResult(RemotePushSyncStatus.failed, error: e);
    }
  }

  Future<void> disableForActiveServer({
    required bool removeServerWebhook,
  }) async {
    final api = _ref.read(apiServiceProvider);
    if (api == null) return;
    final subscription = await _store.read(api.serverConfig.id);
    if (subscription == null) return;

    if (removeServerWebhook) {
      try {
        await api.updateUserNotificationWebhook(
          webhookUrl: null,
          expectedCurrentWebhookUrl: subscription.webhookUrl,
        );
      } on UserNotificationWebhookConflictException {
        // The user or another integration replaced the webhook; leave it alone.
      } catch (e, st) {
        DebugLogger.error(
          'failed to remove remote push webhook',
          error: e,
          stackTrace: st,
          scope: 'notifications/push',
        );
      }
    }

    await _unregisterSubscriptionBestEffort(subscription);
    await _store.delete(subscription.serverId);
  }

  Future<void> unregisterAllLocalSubscriptions() async {
    final subscriptions = await _store.readAll();
    for (final subscription in subscriptions) {
      await _unregisterSubscriptionBestEffort(subscription);
      await _store.delete(subscription.serverId);
    }
  }

  Future<void> _unregisterSubscriptionBestEffort(
    RemotePushSubscription subscription,
  ) async {
    try {
      await _unregisterBestEffort(
        _clientForSubscription(subscription),
        subscription,
      );
    } catch (e, st) {
      DebugLogger.error(
        'remote push unregister setup failed',
        error: e,
        stackTrace: st,
        scope: 'notifications/push',
      );
    }
  }

  Future<void> _unregisterBestEffort(
    RemotePushProxyClient client,
    RemotePushSubscription subscription,
  ) async {
    try {
      await client.unregister(subscription);
    } catch (e, st) {
      DebugLogger.error(
        'remote push unregister failed',
        error: e,
        stackTrace: st,
        scope: 'notifications/push',
      );
    }
  }

  RemotePushProxyClient _clientForSubscription(
    RemotePushSubscription subscription,
  ) {
    final uri = Uri.tryParse(subscription.proxyBaseUrl) ?? _config.proxyBaseUri;
    if (uri == null) {
      throw StateError('remote push subscription has no proxy base URL');
    }
    return _proxyClientFactory(uri);
  }

  Future<BackendConfig?> _freshBackendConfig() async {
    try {
      await _ref.read(backendConfigProvider.notifier).refresh();
    } catch (e, st) {
      DebugLogger.error(
        'failed to refresh backend config for remote push',
        error: e,
        stackTrace: st,
        scope: 'notifications/push',
      );
    }
    return _ref.read(backendConfigProvider).value;
  }

  Future<User?> _currentUser() async {
    final current = _ref.read(currentUserProvider).value;
    if (current != null) return current;
    try {
      return await _ref
          .read(currentUserProvider.future)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _tapSub?.cancel();
    _tokenRefreshSub?.cancel();
    _tokenProvider.dispose();
    _taps.close();
  }
}

final remotePushServiceProvider = Provider<RemotePushService>((ref) {
  final service = RemotePushService(
    ref: ref,
    config: RemotePushBuildConfig.current,
    store: RemotePushSubscriptionStore(ref.watch(secureStorageProvider)),
    tokenProvider: FirebaseRemotePushTokenProvider(
      config: RemotePushBuildConfig.current,
    ),
  );
  ref.onDispose(service.dispose);
  return service;
});
