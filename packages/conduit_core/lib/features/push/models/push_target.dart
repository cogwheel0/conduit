import 'package:conduit_core/features/hermes/models/hermes_config.dart';

/// Which kind of server a push target is.
enum PushTargetKind { openWebUi, hermes }

/// Which Open WebUI replies notify: only chats started from Conduit (the
/// default), or every chat of the account.
enum PushOrigin {
  conduit,
  any;

  static PushOrigin parse(Object? value) =>
      value == 'any' ? PushOrigin.any : PushOrigin.conduit;
}

/// Something push can be set up for: one Open WebUI account or one Hermes
/// connection. Its [scope] names it to the platform and in every dedup key.
sealed class PushTarget {
  const PushTarget();

  /// `owui:<accountId>` or `hermes:<connectionId>`.
  String get scope;
  PushTargetKind get kind;

  /// What the user calls it: the account's email or name, or the connection
  /// name. Shown as a push's subtitle when more than one target is on.
  String get label;

  /// Changes whenever the server the subscription lives on changes in a way
  /// that needs a new subscription. Null when no change does.
  String? get serverIdentity;

  static String openWebUiScope(String accountId) => 'owui:$accountId';
  static String hermesScope(String connectionId) => 'hermes:$connectionId';

  /// The kind a [scope] belongs to, or null for an unknown prefix.
  static PushTargetKind? kindOfScope(String scope) {
    if (scope.startsWith('owui:')) return PushTargetKind.openWebUi;
    if (scope.startsWith('hermes:')) return PushTargetKind.hermes;
    return null;
  }

  /// The account or connection id inside [scope].
  static String idOfScope(String scope) {
    final colon = scope.indexOf(':');
    return colon < 0 ? scope : scope.substring(colon + 1);
  }
}

/// One saved Open WebUI account.
final class OpenWebUiPushTarget extends PushTarget {
  const OpenWebUiPushTarget({
    required this.accountId,
    required this.label,
    this.hasSession = true,
  });

  final String accountId;

  @override
  final String label;

  /// False for an account that was signed out of: it shows as needing sign-in
  /// and nothing is sent to its server.
  final bool hasSession;

  @override
  String get scope => PushTarget.openWebUiScope(accountId);

  @override
  PushTargetKind get kind => PushTargetKind.openWebUi;

  // An account is one user on one server: an address edit keeps both, so
  // the subscription stays.
  @override
  String? get serverIdentity => null;

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiPushTarget &&
      other.accountId == accountId &&
      other.label == label &&
      other.hasSession == hasSession;

  @override
  int get hashCode => Object.hash(accountId, label, hasSession);
}

/// One saved Hermes connection.
final class HermesPushTarget extends PushTarget {
  const HermesPushTarget({
    required this.connectionId,
    required this.label,
    required this.baseUrl,
    required this.mode,
    this.desktopProfile = 'default',
    this.credentialsRevision = '',
  });

  final String connectionId;

  @override
  final String label;
  final String baseUrl;
  final HermesBackendMode mode;
  final String desktopProfile;

  /// Changes when the connection's key, sign-in kind or profile changes
  /// (Hermes rotates the connection's document-trust principal then). Never
  /// a secret itself.
  final String credentialsRevision;

  @override
  String get scope => PushTarget.hermesScope(connectionId);

  @override
  PushTargetKind get kind => PushTargetKind.hermes;

  @override
  String get serverIdentity => identityOf(
    baseUrl: baseUrl,
    mode: mode,
    desktopProfile: desktopProfile,
    credentialsRevision: credentialsRevision,
  );

  /// [serverIdentity] for a connection with these settings.
  static String identityOf({
    required String baseUrl,
    required HermesBackendMode mode,
    required String desktopProfile,
    required String credentialsRevision,
  }) => [
    HermesConfig.connectionEndpoint(baseUrl) ?? baseUrl,
    mode.name,
    if (mode == HermesBackendMode.desktopGateway) desktopProfile,
    credentialsRevision,
  ].join('|');

  @override
  bool operator ==(Object other) =>
      other is HermesPushTarget &&
      other.connectionId == connectionId &&
      other.label == label &&
      other.baseUrl == baseUrl &&
      other.mode == mode &&
      other.desktopProfile == desktopProfile &&
      other.credentialsRevision == credentialsRevision;

  @override
  int get hashCode => Object.hash(
    connectionId,
    label,
    baseUrl,
    mode,
    desktopProfile,
    credentialsRevision,
  );
}
