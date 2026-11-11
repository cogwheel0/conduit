import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/ports/push_platform_port.dart';

/// Where one target's push setup stands.
enum PushStatus {
  /// Push is off, or the user opted this target out.
  off,

  /// Creating keys, registering the endpoint, or subscribing.
  settingUp,

  /// Waiting for the test push to arrive on this device.
  verifying,

  /// A test push decrypted on this device.
  on,

  /// Open WebUI has no active Conduit Push function, and the user is not an
  /// admin. The UI offers a share sheet for the admin.
  needsAdminSetup,

  /// Open WebUI has no active Conduit Push function, and the user is an
  /// admin: [PushCoordinator.installOpenWebUiFunction] installs it.
  canInstall,

  /// Push works, and the user is an admin of a server whose function is
  /// older than the one bundled with the app.
  updateAvailable,

  /// The Open WebUI server runs with `ENABLE_PLUGINS=false`.
  pluginsDisabled,

  /// The server is too old: Open WebUI before 0.11.0, or a Hermes without
  /// platform event routes.
  serverTooOld,

  /// The Hermes `conduit` plugin is missing or not enabled.
  /// [PushTargetState.hermesInstallCommand] has the command to run.
  needsHermesPlugin,

  /// The Hermes plugin is installed, and Hermes has to restart to load it.
  restartHermes,

  /// The account's or connection's session is gone or expired.
  signInNeeded,

  /// No push transport can reach this device: the build has no relay, or
  /// the relay refuses this app.
  relayUnavailable,

  /// The user denied notification permission.
  permissionDenied,

  /// Something failed; [PushTargetState.failure] says what.
  failed;

  /// Whether the UI should offer the user something to do.
  bool get needsAction => switch (this) {
    PushStatus.needsAdminSetup ||
    PushStatus.canInstall ||
    PushStatus.updateAvailable ||
    PushStatus.pluginsDisabled ||
    PushStatus.serverTooOld ||
    PushStatus.needsHermesPlugin ||
    PushStatus.restartHermes ||
    PushStatus.signInNeeded ||
    PushStatus.relayUnavailable ||
    PushStatus.permissionDenied ||
    PushStatus.failed => true,
    PushStatus.off ||
    PushStatus.settingUp ||
    PushStatus.verifying ||
    PushStatus.on => false,
  };
}

/// Why a target [PushStatus.failed].
enum PushFailureReason {
  /// No transport is available: no relay for APNs/FCM and no UnifiedPush
  /// distributor installed.
  noTransport,

  /// The platform could not produce a device token.
  noToken,

  /// The UnifiedPush distributor did not answer with an endpoint.
  distributorFailed,

  /// The relay could not be reached or answered an error.
  relayError,

  /// The relay is rate limiting registrations.
  relayRateLimited,

  /// The server could not be reached.
  serverUnreachable,

  /// The server rejected the request (detail has its error code).
  serverRejected,

  /// The Hermes API key was refused (detail has the plugin's code).
  hermesAuthFailed,

  /// The subscription did not stick on the server.
  subscriptionLost,

  /// Installing the function or plugin failed. Detail has the server's
  /// message, including a Hermes plugin scan that came back "caution".
  installFailed,

  /// The test push was sent but did not arrive in time. Diagnostics, when
  /// the server recorded any, say why.
  testTimeout,

  /// The server could not deliver the test push (detail has its error).
  deliveryFailed,

  /// The platform failed to create or store keys.
  platformError,

  unknown,
}

/// A failure, with the server's or platform's own words when there are any.
final class PushFailure {
  const PushFailure(this.reason, {this.detail});

  final PushFailureReason reason;

  /// A short machine-readable code or message, never a secret: an Open WebUI
  /// delivery category (`blocked`, `gone`, …), a Hermes op error, an HTTP
  /// status, or an install error message.
  final String? detail;

  Map<String, Object?> toJson() => {
    'reason': reason.name,
    if (detail != null) 'detail': detail,
  };

  static PushFailure? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['reason'];
    final reason = PushFailureReason.values.firstWhere(
      (value) => value.name == name,
      orElse: () => PushFailureReason.unknown,
    );
    final detail = json['detail'];
    return PushFailure(reason, detail: detail is String ? detail : null);
  }

  @override
  bool operator ==(Object other) =>
      other is PushFailure && other.reason == reason && other.detail == detail;

  @override
  int get hashCode => Object.hash(reason, detail);

  @override
  String toString() =>
      'PushFailure(${reason.name}${detail == null ? '' : ': $detail'})';
}

/// What a server recorded about delivering to one subscription.
///
/// For Open WebUI this is the function's `status[sid]` valve entry: `code` is
/// the push endpoint's HTTP status (null when nothing was sent) and `err` one
/// of `blocked`, `invalid`, `gone`, `timeout`, `network`, `rate_limited`,
/// `server_error`, `too_large`, `rejected` or `encrypt`. For Hermes it is the
/// `push_status` a test returned.
final class PushServerDiagnostics {
  const PushServerDiagnostics({this.code, this.at, this.error, this.nonce});

  final int? code;
  final DateTime? at;
  final String? error;
  final String? nonce;

  bool get delivered => error == null && code != null && code! < 300;

  static PushServerDiagnostics? fromStatusEntry(Object? entry) {
    if (entry is! Map) return null;
    final code = entry['code'];
    final at = entry['at'];
    final err = entry['err'];
    final nonce = entry['nonce'];
    return PushServerDiagnostics(
      code: code is num ? code.toInt() : null,
      at: at is num
          ? DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000, isUtc: true)
          : null,
      error: err is String && err.isNotEmpty ? err : null,
      nonce: nonce is String ? nonce : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PushServerDiagnostics &&
      other.code == code &&
      other.at == at &&
      other.error == error &&
      other.nonce == nonce;

  @override
  int get hashCode => Object.hash(code, at, error, nonce);

  @override
  String toString() =>
      'PushServerDiagnostics(code: $code, err: $error, at: $at)';
}

/// One target as the UI shows it.
final class PushTargetState {
  const PushTargetState({
    required this.target,
    this.status = PushStatus.off,
    this.failure,
    this.hermesInstallCommand,
    this.canInstallHermesPlugin = false,
    this.diagnostics,
    this.origin = PushOrigin.conduit,
    this.optedOut = false,
    this.notificationsOff = false,
    this.verifiedAt,
    this.transport,
    this.serverVersion,
    this.pluginVersion,
    this.bundledVersion,
  });

  final PushTarget target;
  final PushStatus status;
  final PushFailure? failure;

  /// The command that installs and enables the Hermes plugin, for
  /// [PushStatus.needsHermesPlugin] and [PushStatus.restartHermes].
  final String? hermesInstallCommand;

  /// Whether [PushCoordinator.installHermesPlugin] can install it in one tap
  /// (the connection uses the Hermes dashboard).
  final bool canInstallHermesPlugin;

  /// What the server last recorded about delivering here, when known.
  final PushServerDiagnostics? diagnostics;
  final PushOrigin origin;
  final bool optedOut;

  /// The Open WebUI account's own notifications switch is off, so its pushes
  /// arrive but are not shown.
  final bool notificationsOff;

  /// When a test push last decrypted on this device for the current
  /// subscription.
  final DateTime? verifiedAt;
  final PushTransport? transport;

  /// The Open WebUI or Hermes version, when the probe learned it.
  final String? serverVersion;

  /// The installed function's or plugin's version.
  final String? pluginVersion;

  /// The version of the function bundled with this app (Open WebUI only).
  final String? bundledVersion;

  String get scope => target.scope;
  bool get isVerified => verifiedAt != null;

  PushTargetState copyWith({
    PushTarget? target,
    PushStatus? status,
    PushFailure? failure,
    bool clearFailure = false,
    String? hermesInstallCommand,
    bool clearHermesInstallCommand = false,
    bool? canInstallHermesPlugin,
    PushServerDiagnostics? diagnostics,
    bool clearDiagnostics = false,
    PushOrigin? origin,
    bool? optedOut,
    bool? notificationsOff,
    DateTime? verifiedAt,
    bool clearVerifiedAt = false,
    PushTransport? transport,
    bool clearTransport = false,
    String? serverVersion,
    String? pluginVersion,
    String? bundledVersion,
  }) => PushTargetState(
    target: target ?? this.target,
    status: status ?? this.status,
    failure: clearFailure ? null : failure ?? this.failure,
    hermesInstallCommand: clearHermesInstallCommand
        ? null
        : hermesInstallCommand ?? this.hermesInstallCommand,
    canInstallHermesPlugin:
        canInstallHermesPlugin ?? this.canInstallHermesPlugin,
    diagnostics: clearDiagnostics ? null : diagnostics ?? this.diagnostics,
    origin: origin ?? this.origin,
    optedOut: optedOut ?? this.optedOut,
    notificationsOff: notificationsOff ?? this.notificationsOff,
    verifiedAt: clearVerifiedAt ? null : verifiedAt ?? this.verifiedAt,
    transport: clearTransport ? null : transport ?? this.transport,
    serverVersion: serverVersion ?? this.serverVersion,
    pluginVersion: pluginVersion ?? this.pluginVersion,
    bundledVersion: bundledVersion ?? this.bundledVersion,
  );

  @override
  bool operator ==(Object other) =>
      other is PushTargetState &&
      other.target == target &&
      other.status == status &&
      other.failure == failure &&
      other.hermesInstallCommand == hermesInstallCommand &&
      other.canInstallHermesPlugin == canInstallHermesPlugin &&
      other.diagnostics == diagnostics &&
      other.origin == origin &&
      other.optedOut == optedOut &&
      other.notificationsOff == notificationsOff &&
      other.verifiedAt == verifiedAt &&
      other.transport == transport &&
      other.serverVersion == serverVersion &&
      other.pluginVersion == pluginVersion &&
      other.bundledVersion == bundledVersion;

  @override
  int get hashCode => Object.hash(
    target,
    status,
    failure,
    hermesInstallCommand,
    canInstallHermesPlugin,
    diagnostics,
    origin,
    optedOut,
    notificationsOff,
    verifiedAt,
    transport,
    serverVersion,
    pluginVersion,
    bundledVersion,
  );

  @override
  String toString() =>
      'PushTargetState($scope, ${status.name}'
      '${failure == null ? '' : ', $failure'})';
}

/// The Android delivery service the user picked.
enum PushAndroidTransport {
  fcm,
  unifiedPush;

  static PushAndroidTransport? tryParse(String? value) {
    for (final transport in values) {
      if (transport.name == value) return transport;
    }
    return null;
  }
}

/// Everything push, for the settings UI.
final class PushState {
  const PushState({
    this.enabled = false,
    this.relayConfigured = false,
    this.availableTransports = const [],
    this.transportsChecked = false,
    this.androidTransport,
    this.distributor,
    this.effectiveTransport,
    this.permissionDenied = false,
    this.targets = const {},
  });

  /// The device-wide master toggle.
  final bool enabled;

  /// Whether this build was given a relay URL. Without one, APNs and FCM
  /// cannot be used; UnifiedPush still can.
  final bool relayConfigured;
  final List<PushTransport> availableTransports;

  /// Whether [availableTransports] was read from the platform yet.
  final bool transportsChecked;

  /// Whether push can work in this build on this device: the relay reaches
  /// APNs or FCM, or a UnifiedPush distributor is installed. True until the
  /// transports were checked.
  bool get available =>
      !transportsChecked ||
      availableTransports.contains(PushTransport.unifiedPush) ||
      (relayConfigured &&
          (availableTransports.contains(PushTransport.apns) ||
              availableTransports.contains(PushTransport.fcm)));

  /// The Android delivery service the user chose, or null for automatic
  /// (FCM when available, otherwise UnifiedPush).
  final PushAndroidTransport? androidTransport;

  /// The UnifiedPush distributor package the user chose, or null for the
  /// first installed one.
  final String? distributor;

  /// The transport new subscriptions use, or null when none can.
  final PushTransport? effectiveTransport;
  final bool permissionDenied;

  /// Every target by scope, in the order accounts and connections are listed.
  final Map<String, PushTargetState> targets;

  int get onCount =>
      targets.values.where((t) => t.status == PushStatus.on).length;

  PushState copyWith({
    bool? enabled,
    bool? relayConfigured,
    List<PushTransport>? availableTransports,
    bool? transportsChecked,
    PushAndroidTransport? androidTransport,
    bool clearAndroidTransport = false,
    String? distributor,
    bool clearDistributor = false,
    PushTransport? effectiveTransport,
    bool clearEffectiveTransport = false,
    bool? permissionDenied,
    Map<String, PushTargetState>? targets,
  }) => PushState(
    enabled: enabled ?? this.enabled,
    relayConfigured: relayConfigured ?? this.relayConfigured,
    availableTransports: availableTransports ?? this.availableTransports,
    transportsChecked: transportsChecked ?? this.transportsChecked,
    androidTransport: clearAndroidTransport
        ? null
        : androidTransport ?? this.androidTransport,
    distributor: clearDistributor ? null : distributor ?? this.distributor,
    effectiveTransport: clearEffectiveTransport
        ? null
        : effectiveTransport ?? this.effectiveTransport,
    permissionDenied: permissionDenied ?? this.permissionDenied,
    targets: targets ?? this.targets,
  );
}
