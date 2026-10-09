import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';

/// The subscription a server stores for this device (PROTOCOL §1).
final class PushServerSubscription {
  const PushServerSubscription({
    required this.sid,
    required this.did,
    required this.endpoint,
    required this.p256dh,
    required this.auth,
    required this.events,
    required this.label,
    required this.platform,
    this.origin = PushOrigin.conduit,
  });

  final String sid;

  /// Random per-install id. A server replaces older entries with the same one.
  final String did;
  final String endpoint;
  final String p256dh;
  final String auth;

  /// `reply`, `reply_failed`, `channel` (Open WebUI), `cron` (Hermes).
  final List<String> events;
  final String label;

  /// `ios` or `android`.
  final String platform;

  /// Open WebUI only.
  final PushOrigin origin;

  static const int protocol = 1;

  /// The entry as both servers expect it, without `seen`, `origin` or `test`,
  /// which only Open WebUI uses.
  Map<String, Object?> toJson() => {
    'sid': sid,
    'did': did,
    'endpoint': endpoint,
    'p256dh': p256dh,
    'auth': auth,
    'events': events,
    'label': label,
    'platform': platform,
    'proto': protocol,
  };
}

/// What a probe found on the server.
enum PushProbeOutcome {
  /// Subscriptions can be written.
  ready,
  needsAdminSetup,
  canInstall,
  pluginsDisabled,
  serverTooOld,
  needsHermesPlugin,
  restartHermes,
  signInNeeded,

  /// The probe failed; [PushProbe.failure] says why.
  failed,
}

/// The result of [PushBackend.probe].
final class PushProbe {
  const PushProbe(
    this.outcome, {
    this.failure,
    this.updateAvailable = false,
    this.hermesInstallCommand,
    this.canInstallHermesPlugin = false,
    this.serverVersion,
    this.pluginVersion,
    this.bundledVersion,
  });

  const PushProbe.ready({
    bool updateAvailable = false,
    String? serverVersion,
    String? pluginVersion,
    String? bundledVersion,
  }) : this(
         PushProbeOutcome.ready,
         updateAvailable: updateAvailable,
         serverVersion: serverVersion,
         pluginVersion: pluginVersion,
         bundledVersion: bundledVersion,
       );

  final PushProbeOutcome outcome;
  final PushFailure? failure;

  /// The server's copy works but is older than the one this app ships, and
  /// the user may update it (Open WebUI admins).
  final bool updateAvailable;
  final String? hermesInstallCommand;
  final bool canInstallHermesPlugin;
  final String? serverVersion;
  final String? pluginVersion;
  final String? bundledVersion;

  bool get isReady => outcome == PushProbeOutcome.ready;

  /// The status a target shows while the probe is not [isReady].
  PushStatus get status => switch (outcome) {
    PushProbeOutcome.ready => PushStatus.settingUp,
    PushProbeOutcome.needsAdminSetup => PushStatus.needsAdminSetup,
    PushProbeOutcome.canInstall => PushStatus.canInstall,
    PushProbeOutcome.pluginsDisabled => PushStatus.pluginsDisabled,
    PushProbeOutcome.serverTooOld => PushStatus.serverTooOld,
    PushProbeOutcome.needsHermesPlugin => PushStatus.needsHermesPlugin,
    PushProbeOutcome.restartHermes => PushStatus.restartHermes,
    PushProbeOutcome.signInNeeded => PushStatus.signInNeeded,
    PushProbeOutcome.failed => PushStatus.failed,
  };

  @override
  String toString() => 'PushProbe(${outcome.name}, $failure)';
}

/// What sending a test push started.
final class PushTestDispatch {
  const PushTestDispatch({this.diagnostics});

  /// Set when the server delivered synchronously (Hermes answers with the
  /// push endpoint's status). Open WebUI sends in the background, so its
  /// result arrives later in the `status` valve.
  final PushServerDiagnostics? diagnostics;

  /// Whether the server already knows the push did not go out.
  bool get failedAtServer {
    final diagnostics = this.diagnostics;
    if (diagnostics == null) return false;
    return diagnostics.error != null ||
        diagnostics.code == null ||
        diagnostics.code! < 200 ||
        diagnostics.code! >= 300;
  }
}

/// A backend request failed in a way the coordinator reports.
final class PushBackendException implements Exception {
  const PushBackendException(this.failure, {this.signInNeeded = false});

  final PushFailure failure;

  /// The session behind the request is gone or expired.
  final bool signInNeeded;

  @override
  String toString() => 'PushBackendException($failure)';
}

/// One server's push support: the Open WebUI function or the Hermes plugin.
abstract interface class PushBackend {
  /// Whether the server is ready for subscriptions, and if not, why.
  Future<PushProbe> probe();

  /// Installs, enables or updates the server side. Only call after the user
  /// confirmed. Throws [PushBackendException] with
  /// [PushFailureReason.installFailed] when the server refuses.
  Future<void> install();

  /// Writes [subscription]. With [testNonce], also asks the server for a test
  /// push carrying it, in the same request where the server allows that.
  Future<PushTestDispatch?> subscribe(
    PushServerSubscription subscription, {
    String? testNonce,
  });

  /// Removes [sid] from the server.
  Future<void> unsubscribe(String sid);

  /// Asks for a test push for an existing [subscription].
  Future<PushTestDispatch> requestTest(
    PushServerSubscription subscription,
    String nonce,
  );

  /// What the server recorded about delivering to [sid], when it records
  /// anything.
  Future<PushServerDiagnostics?> diagnose(String sid);

  /// Releases connections. The backend is not used afterwards.
  void close();
}
