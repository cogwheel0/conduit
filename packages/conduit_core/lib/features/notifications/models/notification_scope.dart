/// The account or connection a notification belongs to.
///
/// Every [AppNotification] carries one as its `scope` string:
/// `owui:<accountId>`, `hermes:<connectionId>` or `direct`. It prefixes the
/// protocol dedup key to form the app-wide one (docs/push/PROTOCOL.md §2),
/// decides whether the user is already looking at the target, and tells a tap
/// which account or connection to switch to before opening it.
sealed class NotificationScope {
  const NotificationScope();

  /// An Open WebUI account.
  const factory NotificationScope.openWebUi(String accountId) =
      OpenWebUiNotificationScope;

  /// A saved Hermes connection.
  const factory NotificationScope.hermes(String connectionId) =
      HermesNotificationScope;

  /// The on-device Direct connections, which have no account.
  const factory NotificationScope.direct() = DirectNotificationScope;

  static const String _openWebUiPrefix = 'owui:';
  static const String _hermesPrefix = 'hermes:';
  static const String _direct = 'direct';

  /// Parses a scope string; null for anything that isn't one.
  static NotificationScope? tryParse(String? value) {
    if (value == null) return null;
    if (value == _direct) return const DirectNotificationScope();
    if (value.startsWith(_openWebUiPrefix)) {
      final id = value.substring(_openWebUiPrefix.length);
      return id.isEmpty ? null : OpenWebUiNotificationScope(id);
    }
    if (value.startsWith(_hermesPrefix)) {
      final id = value.substring(_hermesPrefix.length);
      return id.isEmpty ? null : HermesNotificationScope(id);
    }
    return null;
  }

  /// The scope string stored on a notification.
  String get value;

  /// The app-wide dedup key for the protocol key [key] in this scope.
  String dedupKey(String key) => '$value|$key';

  @override
  String toString() => value;
}

final class OpenWebUiNotificationScope extends NotificationScope {
  const OpenWebUiNotificationScope(this.accountId);

  final String accountId;

  @override
  String get value => '${NotificationScope._openWebUiPrefix}$accountId';

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiNotificationScope && other.accountId == accountId;

  @override
  int get hashCode => Object.hash(OpenWebUiNotificationScope, accountId);
}

final class HermesNotificationScope extends NotificationScope {
  const HermesNotificationScope(this.connectionId);

  final String connectionId;

  @override
  String get value => '${NotificationScope._hermesPrefix}$connectionId';

  @override
  bool operator ==(Object other) =>
      other is HermesNotificationScope && other.connectionId == connectionId;

  @override
  int get hashCode => Object.hash(HermesNotificationScope, connectionId);
}

final class DirectNotificationScope extends NotificationScope {
  const DirectNotificationScope();

  @override
  String get value => NotificationScope._direct;

  @override
  bool operator ==(Object other) => other is DirectNotificationScope;

  @override
  int get hashCode => (DirectNotificationScope).hashCode;
}
