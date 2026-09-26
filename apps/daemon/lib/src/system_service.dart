import 'dart:async';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:path/path.dart' as p;

import 'daemon_paths.dart';
import 'log.dart';

/// Implements the `system.*` family.
///
/// Capabilities stay empty until the daemon has a server to interrogate — reporting `true` for a feature the core
/// cannot yet serve would light up sidebar entries that dead-end.
class SystemService {
  SystemService({
    required this.directories,
    required this.daemonVersion,
    required DaemonLog log,
    required Future<void> Function() onShutdownRequested,
    DateTime? startedAt,
  }) : _log = log,
       _onShutdownRequested = onShutdownRequested,
       _startedAt = startedAt ?? DateTime.now();

  final DaemonDirectories directories;
  final String daemonVersion;
  final DaemonLog _log;
  final Future<void> Function() _onShutdownRequested;
  final DateTime _startedAt;

  /// What this daemon can currently serve.
  ///
  /// Replaced when a server is selected, and the daemon then emits
  /// [ConduitEvents.capabilitiesChanged] so open windows re-gate their
  /// navigation without reconnecting.
  Capabilities capabilities = Capabilities.none;

  HandshakeResponse handshake({
    required String sessionId,
    required HandshakeRequest request,
  }) => HandshakeResponse(
    protocolVersion: kConduitProtocolVersion,
    daemonVersion: daemonVersion,
    sessionId: sessionId,
    capabilities: capabilities,
    paths: directories.paths,
    platform: currentPlatform,
    // Always true here: the renderer decides from the server list and the
    // session whether onboarding is needed.
    needsOnboarding: true,
  );

  PongResult ping() => PongResult(
    uptimeMs: DateTime.now().difference(_startedAt).inMilliseconds,
    serverTimeMs: DateTime.now().toUtc().millisecondsSinceEpoch,
  );

  Future<ShutdownResult> shutdown() async {
    _log.info('shutdown requested over RPC');
    // Hand control back to the server loop *after* this reply is written;
    // tearing the socket down inside the handler would make the caller see a
    // transport error instead of a result.
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 50),
        _onShutdownRequested,
      ),
    );
    // Not yet a real outbox flush and database checkpoint.
    return const ShutdownResult(flushed: true);
  }

  Future<DiagnosticsExport> exportDiagnostics() async {
    // A stub rather than a real zip of rotated logs, which is still to come.
    // It keeps the method's contract honest: callers get a path that
    // exists, so the shell's "reveal in folder" works from day one.
    final stamp = DateTime.now().toUtc().toIso8601String().split('T').first;
    final file = File(
      p.join(directories.paths.staging, 'diagnostics-$stamp.txt'),
    );
    await file.writeAsString(
      'conduitd $daemonVersion\n'
      'platform: $currentPlatform\n'
      'uptimeMs: ${ping().uptimeMs}\n'
      'userData: ${directories.paths.userData}\n',
    );
    final length = await file.length();
    return DiagnosticsExport(path: file.path, sizeBytes: length);
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
