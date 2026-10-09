/// End-to-end-encrypted push notifications, as far as the host can do them.
///
/// The keys live with the platform, not with Dart: the iOS Notification
/// Service Extension and the Android receiver decrypt a push without the
/// Flutter engine, so they own the key store (Keychain on iOS, a
/// Keystore-wrapped file on Android). The core only creates subscriptions,
/// hands their endpoints to the user's servers, and mirrors the display
/// settings the platform needs to show a push on its own.
///
/// The types mirror the pigeon `PushHostApi` / `PushFlutterApi` one for one,
/// so the mobile adapter is a pure conversion. Desktop, web, the daemon and
/// unit tests use [UnsupportedPushPlatform]. See `docs/push/PROTOCOL.md`.
library;

/// How a push reaches this device.
enum PushTransport {
  /// Apple Push Notification service, through the Conduit relay.
  apns,

  /// Firebase Cloud Messaging, through the Conduit relay.
  fcm,

  /// A UnifiedPush distributor on Android. Servers post straight to it; the
  /// relay is not involved.
  unifiedPush;

  /// The relay's `provider` value, or null when the relay is not involved.
  String? get relayProvider => switch (this) {
    PushTransport.apns => 'apns',
    PushTransport.fcm => 'fcm',
    PushTransport.unifiedPush => null,
  };

  static PushTransport? tryParse(String? value) {
    for (final transport in PushTransport.values) {
      if (transport.name == value) return transport;
    }
    return null;
  }
}

/// One subscription: a P-256 key pair and auth secret the platform keeps,
/// for one Open WebUI account or Hermes connection.
class PushSubscriptionKeys {
  const PushSubscriptionKeys({
    required this.sid,
    required this.scope,
    required this.p256dh,
    required this.auth,
    required this.createdAt,
    this.endpoint,
    this.transport,
  });

  /// 16 random bytes, base64url without padding. Names the key pair in every
  /// push.
  final String sid;

  /// `owui:<accountId>` or `hermes:<connectionId>`.
  final String scope;

  /// Uncompressed P-256 public key, base64url.
  final String p256dh;

  /// 16-byte auth secret, base64url.
  final String auth;
  final DateTime createdAt;

  /// The endpoint last stored with [PushPlatformPort.setEndpoint].
  final String? endpoint;
  final PushTransport? transport;

  @override
  String toString() => 'PushSubscriptionKeys(sid: $sid, scope: $scope)';
}

/// A device token for [transport].
class PushDeviceToken {
  const PushDeviceToken({
    required this.transport,
    required this.token,
    required this.app,
    required this.env,
  });

  final PushTransport transport;

  /// Hex APNs device token or FCM registration token. Never persisted by the
  /// core; only its SHA-256 fingerprint is.
  final String token;

  /// Bundle id or application id the relay addresses.
  final String app;

  /// `prod` or `dev` (the APNs sandbox).
  final String env;

  @override
  String toString() => 'PushDeviceToken(${transport.name}, app: $app, $env)';
}

/// What the platform needs to show a push without the Flutter engine.
class PushDisplayConfig {
  const PushDisplayConfig({
    required this.enabled,
    required this.sound,
    required this.enabledKinds,
    required this.disabledScopes,
    required this.scopeLabels,
    required this.showScopeLabel,
    required this.strings,
  });

  /// False drops every push (the user turned push or notifications off).
  final bool enabled;
  final bool sound;

  /// `cp/1` kinds to show: `reply`, `reply_failed`, `channel`, `cron`, `test`.
  final List<String> enabledKinds;

  /// Scopes the user opted out of on this device.
  final List<String> disabledScopes;

  /// Account or connection name per scope, shown as the subtitle.
  final Map<String, String> scopeLabels;
  final bool showScopeLabel;

  /// Localized strings keyed `fallbackTitle`, `fallbackBody`, `replyTitle`,
  /// `replyFailedTitle`, `replyFailedBody`, `channelTitle`, `cronTitle`,
  /// `testTitle`, `testBody`.
  final Map<String, String> strings;

  @override
  bool operator ==(Object other) =>
      other is PushDisplayConfig &&
      other.enabled == enabled &&
      other.sound == sound &&
      _listEquals(other.enabledKinds, enabledKinds) &&
      _listEquals(other.disabledScopes, disabledScopes) &&
      _mapEquals(other.scopeLabels, scopeLabels) &&
      other.showScopeLabel == showScopeLabel &&
      _mapEquals(other.strings, strings);

  @override
  int get hashCode => Object.hash(
    enabled,
    sound,
    Object.hashAll(enabledKinds),
    Object.hashAll(disabledScopes),
    Object.hashAllUnordered(
      scopeLabels.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    showScopeLabel,
    Object.hashAllUnordered(
      strings.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

/// A decrypted push handed to Dart while the app is in the foreground.
class PushMessage {
  const PushMessage({
    required this.sid,
    required this.scope,
    required this.payloadJson,
  });

  final String sid;
  final String scope;

  /// The `cp/1` plaintext.
  final String payloadJson;
}

/// A tapped push notification.
class PushTap {
  const PushTap({required this.scope, required this.payloadJson});

  final String scope;

  /// The `cp/1` plaintext the notification was built from.
  final String payloadJson;
}

/// Something the platform reported.
sealed class PushPlatformEvent {
  const PushPlatformEvent();
}

/// A new or rotated device token.
final class PushTokenEvent extends PushPlatformEvent {
  const PushTokenEvent(this.token);
  final PushDeviceToken token;
}

/// A push arrived while the app was in the foreground. The platform showed
/// nothing; the notification router decides.
final class PushForegroundEvent extends PushPlatformEvent {
  const PushForegroundEvent(this.message);
  final PushMessage message;
}

/// The user tapped a push notification while the app was running.
final class PushTapEvent extends PushPlatformEvent {
  const PushTapEvent(this.tap);
  final PushTap tap;
}

/// A test push for [sid] decrypted on this device.
final class PushTestReceivedEvent extends PushPlatformEvent {
  const PushTestReceivedEvent(this.sid, this.nonce);
  final String sid;
  final String nonce;
}

/// The push service dropped [sid] (UnifiedPush unregistered it).
final class PushUnregisteredEvent extends PushPlatformEvent {
  const PushUnregisteredEvent(this.sid);
  final String sid;
}

/// A UnifiedPush distributor gave [sid] a new endpoint.
final class PushUnifiedPushEndpointEvent extends PushPlatformEvent {
  const PushUnifiedPushEndpointEvent(this.sid, this.endpoint);
  final String sid;
  final String endpoint;
}

/// The host's push capability.
abstract interface class PushPlatformPort {
  /// Transports this build and device can use. Empty where push is
  /// unsupported.
  Future<List<PushTransport>> availableTransports();

  /// Asks for permission to show notifications. False when denied. May show
  /// the system prompt, so only a user action should call it.
  Future<bool> requestPermission();

  /// Whether notifications may be shown, without ever prompting. Null when
  /// the platform cannot tell.
  Future<bool?> hasPermission();

  /// The current device token, registering for remote notifications first if
  /// needed. Null when [transport] is unavailable.
  Future<PushDeviceToken?> currentToken(PushTransport transport);

  /// Generates a fresh key pair, auth secret and sid for [scope].
  Future<PushSubscriptionKeys> createSubscription(String scope);
  Future<List<PushSubscriptionKeys>> listSubscriptions();
  Future<void> setEndpoint(
    String sid,
    String endpoint,
    PushTransport transport,
  );

  /// Deletes the keys for [sid]. A push for it can no longer be read.
  Future<void> deleteSubscription(String sid);
  Future<void> setConfig(PushDisplayConfig config);

  /// Records [dedupKey] as shown. False when a push or a local notification
  /// already claimed it.
  Future<bool> claimNotification(
    String dedupKey, {
    String? localNotificationId,
  });

  /// Removes delivered notifications that belong to [scope].
  Future<void> cancelScope(String scope);

  /// The push notification that launched the app, once.
  Future<PushTap?> takeLaunchTap();

  /// Test nonces decrypted for [sid] since the last call.
  Future<List<String>> takeVerifiedNonces(String sid);

  /// Installed UnifiedPush distributors (package names). Android only.
  Future<List<String>> unifiedPushDistributors();

  /// Registers [sid] with [distributor] and answers its endpoint, or null
  /// when the distributor refuses or does not answer in time.
  Future<String?> registerUnifiedPush(String sid, String distributor);
  Future<void> unregisterUnifiedPush(String sid);

  /// Tokens, foreground pushes, taps, test receipts, unregistrations and
  /// UnifiedPush endpoint changes. A broadcast stream.
  Stream<PushPlatformEvent> get events;

  /// The host's implementation, installed once at startup.
  static PushPlatformPort hostDefault = const UnsupportedPushPlatform();
}

/// Push is not available: desktop, web, the daemon, and unit tests.
///
/// Every query answers "nothing here", and [claimNotification] always
/// grants the claim, because without push nothing else can show a
/// notification first.
class UnsupportedPushPlatform implements PushPlatformPort {
  const UnsupportedPushPlatform();

  @override
  Future<List<PushTransport>> availableTransports() async => const [];

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<bool?> hasPermission() async => null;

  @override
  Future<PushDeviceToken?> currentToken(PushTransport transport) async => null;

  @override
  Future<PushSubscriptionKeys> createSubscription(String scope) =>
      Future.error(UnsupportedError('Push is not available on this host.'));

  @override
  Future<List<PushSubscriptionKeys>> listSubscriptions() async => const [];

  @override
  Future<void> setEndpoint(
    String sid,
    String endpoint,
    PushTransport transport,
  ) async {}

  @override
  Future<void> deleteSubscription(String sid) async {}

  @override
  Future<void> setConfig(PushDisplayConfig config) async {}

  @override
  Future<bool> claimNotification(
    String dedupKey, {
    String? localNotificationId,
  }) async => true;

  @override
  Future<void> cancelScope(String scope) async {}

  @override
  Future<PushTap?> takeLaunchTap() async => null;

  @override
  Future<List<String>> takeVerifiedNonces(String sid) async => const [];

  @override
  Future<List<String>> unifiedPushDistributors() async => const [];

  @override
  Future<String?> registerUnifiedPush(String sid, String distributor) async =>
      null;

  @override
  Future<void> unregisterUnifiedPush(String sid) async {}

  @override
  Stream<PushPlatformEvent> get events =>
      const Stream<PushPlatformEvent>.empty();
}

bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
