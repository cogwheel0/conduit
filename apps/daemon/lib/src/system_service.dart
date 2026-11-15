import 'dart:async';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';

import 'daemon_paths.dart';
import 'diagnostics.dart';
import 'log.dart';

/// Implements the `system.*` family.
class SystemService {
  SystemService({
    required this.directories,
    required this.daemonVersion,
    required DaemonLog log,
    required void Function(String reason) requestStop,
    Future<bool> Function()? needsOnboarding,
    Future<int> Function()? flushOutbox,
    Future<Map<String, Object?>> Function()? configSnapshot,
    Iterable<String> secrets = const <String>[],
    DateTime? startedAt,
  }) : _log = log,
       _requestStop = requestStop,
       _needsOnboarding = needsOnboarding,
       _flushOutbox = flushOutbox,
       _configSnapshot = configSnapshot,
       _secrets = List<String>.of(secrets),
       _startedAt = startedAt ?? DateTime.now();

  final DaemonDirectories directories;
  final String daemonVersion;
  final DaemonLog _log;

  /// The daemon's one way to stop: stdin EOF, a signal and
  /// `system.shutdown` all end there.
  final void Function(String reason) _requestStop;

  /// Each null, or answering for nothing, while the core is starting.
  final Future<bool> Function()? _needsOnboarding;
  final Future<int> Function()? _flushOutbox;
  final Future<Map<String, Object?>> Function()? _configSnapshot;

  /// Known by value and kept out of the export: the session token and the
  /// master key.
  final List<String> _secrets;
  final DateTime _startedAt;

  /// What the active account can use now.
  ///
  /// [Capabilities.none] until the core is up; from then on kept current by
  /// the `CapabilitiesService`, which also emits
  /// [ConduitEvents.capabilitiesChanged] so open windows re-gate their
  /// navigation without reconnecting.
  Capabilities capabilities = Capabilities.none;

  Future<HandshakeResponse> handshake({
    required String sessionId,
    required HandshakeRequest request,
  }) async => HandshakeResponse(
    protocolVersion: kConduitProtocolVersion,
    daemonVersion: daemonVersion,
    sessionId: sessionId,
    capabilities: capabilities,
    paths: directories.paths,
    platform: currentPlatform,
    // From the core's routing policy once it is up. Before then nobody
    // knows, and false only costs the window the round trip that finds out:
    // true would show onboarding to someone who is signed in.
    needsOnboarding: await _onboarding(),
  );

  Future<bool> _onboarding() async {
    final ask = _needsOnboarding;
    if (ask == null) return false;
    try {
      return await ask();
    } on Object catch (error) {
      _log.warn('could not tell whether onboarding is needed: $error');
      return false;
    }
  }

  PongResult ping() => PongResult(
    uptimeMs: DateTime.now().difference(_startedAt).inMilliseconds,
    serverTimeMs: DateTime.now().toUtc().millisecondsSinceEpoch,
  );

  /// Sends what the outbox holds, within its budget, then stops the daemon
  /// the way closing stdin does.
  ///
  /// The reply says whether everything went; what did not stays on disk and
  /// goes on the next launch.
  Future<ShutdownResult> shutdown() async {
    _log.info('shutdown requested over RPC');
    // -1: the count could not be read, so nothing is claimed to have gone.
    var pending = 0;
    final flush = _flushOutbox;
    if (flush != null) {
      try {
        pending = await flush();
      } on Object catch (error) {
        _log.warn('outbox flush before shutdown failed: $error');
        pending = -1;
      }
    }
    // Hand control back to the server loop *after* this reply is written;
    // tearing the socket down inside the handler would make the caller see a
    // transport error instead of a result.
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 50),
        () => _requestStop('system.shutdown'),
      ),
    );
    return ShutdownResult(
      flushed: pending == 0,
      pendingOutboxEntries: pending < 0 ? 0 : pending,
    );
  }

  /// Zips the daemon's logs and a snapshot of its configuration with every
  /// credential left out, into the staging directory.
  Future<DiagnosticsExport> exportDiagnostics() async {
    final zip = await writeDiagnosticsZip(
      logs: Directory(directories.paths.logs),
      staging: Directory(directories.paths.staging),
      snapshot: await _snapshot(),
      exactSecrets: _secrets,
    );
    _log.info('diagnostics written to ${homeRelative(zip.path)}');
    return DiagnosticsExport(path: zip.path, sizeBytes: await zip.length());
  }

  Future<Map<String, Object?>> _snapshot() async {
    Map<String, Object?> core;
    final snapshot = _configSnapshot;
    if (snapshot == null) {
      core = <String, Object?>{'state': 'starting'};
    } else {
      try {
        core = await snapshot();
      } on Object catch (error) {
        core = <String, Object?>{
          'state': 'unreadable',
          'error': error.runtimeType.toString(),
        };
      }
    }
    return <String, Object?>{
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'daemonVersion': daemonVersion,
      'protocolVersion': kConduitProtocolVersion,
      'platform': currentPlatform,
      'osVersion': Platform.operatingSystemVersion,
      'dartVersion': Platform.version.split(' ').first,
      'uptimeMs': ping().uptimeMs,
      'logLevel': _log.level,
      'paths': <String, String>{
        'userData': homeRelative(directories.paths.userData),
        'logs': homeRelative(directories.paths.logs),
      },
      'capabilities': capabilities.toJson(),
      'core': core,
    };
  }

  /// The platform string the protocol uses. Kept here rather than derived in
  /// the UI so both front-ends agree on the spelling.
  static String get currentPlatform {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem;
  }
}
