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

  /// Whether the user made a choice for this target that is not the
  /// default, which outlives its subscription.
  bool get hasChoices => optedOut || origin != PushOrigin.conduit;

  /// This record with [from]'s choices: a setup that read the record before
  /// the user changed them must not put the old ones back.
  PushSubscriptionRecord withChoicesOf(PushSubscriptionRecord from) =>
      from.optedOut == optedOut && from.origin == origin
      ? this
      : copyWith(optedOut: from.optedOut, origin: from.origin);

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
/// not be reached at the time. It names its account or connection by
/// [scope], which outlives the account being signed out of or the
/// connection being edited, and the server it lives on by [server], so it is
/// only ever removed from that server.
final class PushTombstone {
  const PushTombstone({
    required this.sid,
    required this.scope,
    required this.at,
    this.server,
  });

  final String sid;
  final String scope;
  final DateTime at;

  /// The [PushSubscriptionRecord.serverFingerprint] of the server the
  /// subscription was made on, or null when any server of [scope] is it
  /// (Open WebUI accounts, and keys found only on the platform).
  final String? server;

  Map<String, Object?> toJson() => {
    'sid': sid,
    'scope': scope,
    'at': at.millisecondsSinceEpoch,
    'server': ?server,
  };

  static PushTombstone? fromJson(Object? json) {
    if (json is! Map) return null;
    final sid = json['sid'];
    final scope = json['scope'];
    final at = json['at'];
    final server = json['server'];
    if (sid is! String || scope is! String || at is! int) return null;
    return PushTombstone(
      sid: sid,
      scope: scope,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      server: server is String && server.isNotEmpty ? server : null,
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
