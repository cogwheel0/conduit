import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// A server webhook destination, as Open WebUI lists it.
///
/// The server never returns the destination URL. It returns
/// `config.url_masked`, a display-only string that must never be sent back as
/// a URL, so [config] is kept as the server sent it and read through
/// [maskedUrl].
@immutable
class NotificationTarget {
  const NotificationTarget({
    required this.id,
    required this.type,
    required this.enabled,
    required this.events,
    required this.delivery,
    this.isDefault,
    this.config = const <String, dynamic>{},
    this.createdAt,
    this.updatedAt,
  });

  /// The only target type Open WebUI 0.11 defines.
  static const String webhookType = 'webhook';

  /// Deliver only while the account has no active session.
  static const String deliveryAway = 'away';

  /// Deliver whether or not the account is active.
  static const String deliveryAlways = 'always';

  final String id;
  final String type;

  /// Null when the server omitted `is_default`.
  final bool? isDefault;
  final bool enabled;

  /// Subscribed event ids, kept verbatim. An id this client's catalog does not
  /// list stays here until the user removes it.
  final List<String> events;

  /// `away` or `always`; kept as sent so a mode this client does not know is
  /// not rewritten.
  final String delivery;

  /// Opaque server config, minus any secret. Holds `url_masked`.
  final Map<String, dynamic> config;
  final int? createdAt;
  final int? updatedAt;

  bool get isWebhook => type == webhookType;

  /// Display-only destination, for example `https://hooks.example.com/...ab12`.
  String? get maskedUrl {
    final value = config['url_masked'];
    return value is String && value.isNotEmpty ? value : null;
  }

  factory NotificationTarget.fromJson(Map<String, dynamic> json) {
    final config = json['config'];
    final events = json['events'];
    return NotificationTarget(
      id: (json['id'] ?? '').toString(),
      type: (json['type'] ?? webhookType).toString(),
      isDefault: json['is_default'] is bool ? json['is_default'] as bool : null,
      // The server treats a missing flag as enabled.
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      events: events is List
          ? List<String>.unmodifiable(events.map((event) => event.toString()))
          : const <String>[],
      delivery: (json['delivery'] ?? deliveryAway).toString(),
      config: config is Map
          ? Map<String, dynamic>.unmodifiable(
              config.map((key, value) => MapEntry(key.toString(), value)),
            )
          : const <String, dynamic>{},
      createdAt: _epoch(json['created_at']),
      updatedAt: _epoch(json['updated_at']),
    );
  }

  NotificationTarget copyWith({bool? isDefault}) {
    return NotificationTarget(
      id: id,
      type: type,
      enabled: enabled,
      events: events,
      delivery: delivery,
      isDefault: isDefault ?? this.isDefault,
      config: config,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationTarget &&
      other.id == id &&
      other.type == type &&
      other.isDefault == isDefault &&
      other.enabled == enabled &&
      other.delivery == delivery &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      const ListEquality<String>().equals(other.events, events) &&
      const DeepCollectionEquality().equals(other.config, config);

  @override
  int get hashCode => Object.hash(
    id,
    type,
    isDefault,
    enabled,
    delivery,
    createdAt,
    updatedAt,
    const ListEquality<String>().hash(events),
    const DeepCollectionEquality().hash(config),
  );

  // Deliberately no field dump: [config] can carry a secret reference.
  @override
  String toString() => 'NotificationTarget($id)';
}

/// One entry of the server's event catalog.
///
/// This lists the event kinds a webhook can subscribe to. It is not a record
/// of notifications that were sent.
@immutable
class NotificationEvent {
  const NotificationEvent({
    required this.event,
    required this.label,
    this.description,
  });

  /// The id a target subscribes with, for example `chat.finished`.
  final String event;
  final String label;
  final String? description;

  /// Null for an entry without an event id, which cannot be subscribed to.
  static NotificationEvent? tryParse(Map<String, dynamic> json) {
    final event = json['event'];
    if (event is! String || event.isEmpty) return null;
    final label = json['label'];
    final description = json['description'];
    return NotificationEvent(
      event: event,
      label: label is String && label.isNotEmpty ? label : event,
      description: description is String && description.isNotEmpty
          ? description
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationEvent &&
      other.event == event &&
      other.label == label &&
      other.description == description;

  @override
  int get hashCode => Object.hash(event, label, description);
}

int? _epoch(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}
