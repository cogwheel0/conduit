import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/ports/push_platform_port.dart';

/// What this device remembers about one target's subscription.
///
/// Device-wide, never account-scoped, and never secret: the keys stay with
/// the platform, and a device token is only kept as its SHA-256
/// [tokenFingerprint]. A record without a [sid] still carries the user's
/// per-target choices ([optedOut], [origin]).
final class PushSubscriptionRecord {
  const PushSubscriptionRecord({
    this.sid,
    this.endpoint,
    this.transport,
    this.tokenFingerprint,
    this.kid,
    this.verifiedAt,
    this.optedOut = false,
    this.origin = PushOrigin.conduit,
    this.lastError,
    this.serverFingerprint,
    this.events,
    this.subscribedAt,
  });

  final String? sid;
  final String? endpoint;
  final PushTransport? transport;

  /// SHA-256 (hex) of the device token the relay endpoint was registered
  /// with. A different token means the endpoint must be registered again.
  final String? tokenFingerprint;

  /// The relay key id sealed into [endpoint].
  final int? kid;

  /// When a test push for this [sid] and [endpoint] decrypted here.
  final DateTime? verifiedAt;
  final bool optedOut;
  final PushOrigin origin;
  final PushFailure? lastError;

  /// SHA-256 (hex) of the target's server identity when [sid] was created.
  final String? serverFingerprint;

  /// The notification kinds last sent to the server.
  final List<String>? events;

  /// When the server last accepted this subscription.
  final DateTime? subscribedAt;

  bool get hasSubscription => sid != null;

  PushSubscriptionRecord copyWith({
    String? sid,
    String? endpoint,
    PushTransport? transport,
    String? tokenFingerprint,
    int? kid,
    DateTime? verifiedAt,
    bool? optedOut,
    PushOrigin? origin,
    PushFailure? lastError,
    String? serverFingerprint,
    List<String>? events,
    DateTime? subscribedAt,
    bool clearEndpoint = false,
    bool clearVerifiedAt = false,
    bool clearLastError = false,
    bool clearSubscribedAt = false,
  }) => PushSubscriptionRecord(
    sid: sid ?? this.sid,
    endpoint: clearEndpoint ? null : endpoint ?? this.endpoint,
    transport: clearEndpoint ? null : transport ?? this.transport,
    tokenFingerprint: clearEndpoint
        ? null
        : tokenFingerprint ?? this.tokenFingerprint,
    kid: clearEndpoint ? null : kid ?? this.kid,
    verifiedAt: clearVerifiedAt ? null : verifiedAt ?? this.verifiedAt,
    optedOut: optedOut ?? this.optedOut,
    origin: origin ?? this.origin,
    lastError: clearLastError ? null : lastError ?? this.lastError,
    serverFingerprint: serverFingerprint ?? this.serverFingerprint,
    events: events ?? this.events,
    subscribedAt: clearSubscribedAt ? null : subscribedAt ?? this.subscribedAt,
  );

  /// The same choices with every trace of the subscription dropped.
  PushSubscriptionRecord withoutSubscription() =>
      PushSubscriptionRecord(optedOut: optedOut, origin: origin);

  Map<String, Object?> toJson() => {
    'sid': ?sid,
    'endpoint': ?endpoint,
    'transport': ?transport?.name,
    'tokenFingerprint': ?tokenFingerprint,
    'kid': ?kid,
    'verifiedAt': ?verifiedAt?.millisecondsSinceEpoch,
    if (optedOut) 'optedOut': true,
    if (origin != PushOrigin.conduit) 'origin': origin.name,
    'lastError': ?lastError?.toJson(),
    'serverFingerprint': ?serverFingerprint,
    'events': ?events,
    'subscribedAt': ?subscribedAt?.millisecondsSinceEpoch,
  };

  static PushSubscriptionRecord fromJson(Object? json) {
    if (json is! Map) return const PushSubscriptionRecord();
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    DateTime? time(String key) {
      final value = json[key];
      return value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;
    }

    final events = json['events'];
    final kid = json['kid'];
    return PushSubscriptionRecord(
      sid: text('sid'),
      endpoint: text('endpoint'),
      transport: PushTransport.tryParse(text('transport')),
      tokenFingerprint: text('tokenFingerprint'),
      kid: kid is int ? kid : null,
      verifiedAt: time('verifiedAt'),
      optedOut: json['optedOut'] == true,
      origin: PushOrigin.parse(json['origin']),
      lastError: PushFailure.fromJson(json['lastError']),
      serverFingerprint: text('serverFingerprint'),
      events: events is List ? events.whereType<String>().toList() : null,
      subscribedAt: time('subscribedAt'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PushSubscriptionRecord &&
      other.sid == sid &&
      other.endpoint == endpoint &&
      other.transport == transport &&
      other.tokenFingerprint == tokenFingerprint &&
      other.kid == kid &&
      other.verifiedAt == verifiedAt &&
      other.optedOut == optedOut &&
      other.origin == origin &&
      other.lastError == lastError &&
      other.serverFingerprint == serverFingerprint &&
      _sameList(other.events, events) &&
      other.subscribedAt == subscribedAt;

  @override
  int get hashCode => Object.hash(
    sid,
    endpoint,
    transport,
    tokenFingerprint,
    kid,
    verifiedAt,
    optedOut,
    origin,
    lastError,
    serverFingerprint,
    events == null ? null : Object.hashAll(events!),
    subscribedAt,
  );
}

/// A subscription deleted on this device whose server copy may still exist.
///
/// Kept for 30 days so a later pass can remove it from a server that could
/// not be reached at the time.
final class PushTombstone {
  const PushTombstone({
    required this.sid,
    required this.scope,
    required this.at,
  });

  final String sid;
  final String scope;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'sid': sid,
    'scope': scope,
    'at': at.millisecondsSinceEpoch,
  };

  static PushTombstone? fromJson(Object? json) {
    if (json is! Map) return null;
    final sid = json['sid'];
    final scope = json['scope'];
    final at = json['at'];
    if (sid is! String || scope is! String || at is! int) return null;
    return PushTombstone(
      sid: sid,
      scope: scope,
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

bool _sameList(List<String>? a, List<String>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
