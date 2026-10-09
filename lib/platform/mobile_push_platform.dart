import 'dart:async';

import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'conduit_platform_apis.g.dart';

/// The mobile [PushPlatformPort]: the pigeon `PushHostApi` and
/// `PushFlutterApi`, converted to the core's types.
///
/// The Flutter API is registered on first use rather than in the
/// constructor, because `main` installs the port before the binding exists.
/// A build whose native side has no push bridge answers every call with a
/// channel error; [availableTransports] turns that into "no transports", so
/// the coordinator reports push as unavailable instead of failing.
class MobilePushPlatform implements PushPlatformPort, PushFlutterApi {
  MobilePushPlatform({PushHostApi? hostApi}) : _host = hostApi ?? PushHostApi();

  final PushHostApi _host;
  final StreamController<PushPlatformEvent> _events =
      StreamController<PushPlatformEvent>.broadcast();
  bool _attached = false;

  void _attach() {
    if (_attached) return;
    _attached = true;
    PushFlutterApi.setUp(this);
  }

  Future<T> _call<T>(Future<T> Function() body) {
    _attach();
    return body();
  }

  @override
  Stream<PushPlatformEvent> get events {
    _attach();
    return _events.stream;
  }

  @override
  Future<List<PushTransport>> availableTransports() async {
    try {
      final transports = await _call(_host.availableTransports);
      return [for (final transport in transports) _transport(transport)];
    } on PlatformException catch (error) {
      if (error.code == 'channel-error') return const [];
      rethrow;
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<bool> requestPermission() => _call(_host.requestPermission);

  /// Reads the notification permission without prompting, through
  /// permission_handler, a dependency the app already has.
  @override
  Future<bool?> hasPermission() async {
    try {
      final status = await Permission.notification.status;
      return status.isGranted || status.isLimited || status.isProvisional;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<PushDeviceToken?> currentToken(PushTransport transport) async {
    final token = await _call(
      () => _host.currentToken(_platformTransport(transport)),
    );
    return token == null ? null : _token(token);
  }

  @override
  Future<PushSubscriptionKeys> createSubscription(String scope) async =>
      _subscription(await _call(() => _host.createSubscription(scope)));

  @override
  Future<List<PushSubscriptionKeys>> listSubscriptions() async {
    final list = await _call(_host.listSubscriptions);
    return [for (final subscription in list) _subscription(subscription)];
  }

  @override
  Future<void> setEndpoint(
    String sid,
    String endpoint,
    PushTransport transport,
  ) => _call(
    () => _host.setEndpoint(sid, endpoint, _platformTransport(transport)),
  );

  @override
  Future<void> deleteSubscription(String sid) =>
      _call(() => _host.deleteSubscription(sid));

  @override
  Future<void> setConfig(PushDisplayConfig config) => _call(
    () => _host.setConfig(
      PlatformPushConfig(
        enabled: config.enabled,
        sound: config.sound,
        enabledKinds: List<String>.of(config.enabledKinds),
        disabledScopes: List<String>.of(config.disabledScopes),
        scopeLabels: Map<String, String>.of(config.scopeLabels),
        showScopeLabel: config.showScopeLabel,
        strings: Map<String, String>.of(config.strings),
      ),
    ),
  );

  @override
  Future<bool> claimNotification(
    String dedupKey, {
    String? localNotificationId,
  }) => _call(() => _host.claimNotification(dedupKey, localNotificationId));

  @override
  Future<void> cancelScope(String scope) =>
      _call(() => _host.cancelScope(scope));

  @override
  Future<PushTap?> takeLaunchTap() async {
    final tap = await _call(_host.takeLaunchTap);
    return tap == null
        ? null
        : PushTap(scope: tap.scope, payloadJson: tap.payloadJson);
  }

  @override
  Future<List<String>> takeVerifiedNonces(String sid) =>
      _call(() => _host.takeVerifiedNonces(sid));

  @override
  Future<List<String>> unifiedPushDistributors() =>
      _call(_host.unifiedPushDistributors);

  @override
  Future<String?> registerUnifiedPush(String sid, String distributor) =>
      _call(() => _host.registerUnifiedPush(sid, distributor));

  @override
  Future<void> unregisterUnifiedPush(String sid) =>
      _call(() => _host.unregisterUnifiedPush(sid));

  // PushFlutterApi

  @override
  void onToken(PlatformPushToken token) =>
      _events.add(PushTokenEvent(_token(token)));

  @override
  void onForegroundPush(PlatformPushMessage message) => _events.add(
    PushForegroundEvent(
      PushMessage(
        sid: message.sid,
        scope: message.scope,
        payloadJson: message.payloadJson,
      ),
    ),
  );

  @override
  void onTap(PlatformPushTap tap) => _events.add(
    PushTapEvent(PushTap(scope: tap.scope, payloadJson: tap.payloadJson)),
  );

  @override
  void onTestReceived(String sid, String nonce) =>
      _events.add(PushTestReceivedEvent(sid, nonce));

  @override
  void onUnregistered(String sid) => _events.add(PushUnregisteredEvent(sid));

  @override
  void onUnifiedPushEndpoint(String sid, String endpoint) =>
      _events.add(PushUnifiedPushEndpointEvent(sid, endpoint));

  static PushTransport _transport(PlatformPushTransport transport) =>
      switch (transport) {
        PlatformPushTransport.apns => PushTransport.apns,
        PlatformPushTransport.fcm => PushTransport.fcm,
        PlatformPushTransport.unifiedPush => PushTransport.unifiedPush,
      };

  static PlatformPushTransport _platformTransport(PushTransport transport) =>
      switch (transport) {
        PushTransport.apns => PlatformPushTransport.apns,
        PushTransport.fcm => PlatformPushTransport.fcm,
        PushTransport.unifiedPush => PlatformPushTransport.unifiedPush,
      };

  static PushDeviceToken _token(PlatformPushToken token) => PushDeviceToken(
    transport: _transport(token.transport),
    token: token.token,
    app: token.app,
    env: token.env,
  );

  static PushSubscriptionKeys _subscription(PlatformPushSubscription value) =>
      PushSubscriptionKeys(
        sid: value.sid,
        scope: value.scope,
        p256dh: value.p256dh,
        auth: value.auth,
        createdAt: DateTime.fromMillisecondsSinceEpoch(value.createdAtMillis),
        endpoint: value.endpoint,
        transport: value.transport == null
            ? null
            : _transport(value.transport!),
      );
}
