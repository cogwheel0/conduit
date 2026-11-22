import 'dart:async';

import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';

/// Implements the `system.*` family.
///
/// What every session needs, whatever hosts it. The host says where its
/// data lives ([paths]) and what it runs on ([platform]), how it stops, and
/// how it exports diagnostics, if it does.
class SystemService {
  SystemService({
    required this.paths,
    required this.platform,
    required this.daemonVersion,
    required void Function(String reason) requestStop,
    Future<bool> Function()? needsOnboarding,
    Future<int> Function()? flushOutbox,
    Future<DiagnosticsExport> Function()? exportDiagnostics,
    DateTime? startedAt,
  }) : _requestStop = requestStop,
       _needsOnboarding = needsOnboarding,
       _flushOutbox = flushOutbox,
       _exportDiagnostics = exportDiagnostics,
       _startedAt = startedAt ?? DateTime.now();

  final DaemonPaths paths;

  /// The platform string the protocol uses (`macos`, `windows`, `linux`).
  final String platform;
  final String daemonVersion;

  /// The daemon's one way to stop: stdin EOF, a signal and
  /// `system.shutdown` all end there.
  final void Function(String reason) _requestStop;

  /// Each null, or answering for nothing, while the core is starting.
  final Future<bool> Function()? _needsOnboarding;
  final Future<int> Function()? _flushOutbox;
  final Future<DiagnosticsExport> Function()? _exportDiagnostics;
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
    paths: paths,
    platform: platform,
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
      DebugLogger.warning(
        'could not tell whether onboarding is needed: $error',
        scope: 'daemon/system',
      );
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
    DebugLogger.info('shutdown requested over RPC', scope: 'daemon/system');
    // -1: the count could not be read, so nothing is claimed to have gone.
    var pending = 0;
    final flush = _flushOutbox;
    if (flush != null) {
      try {
        pending = await flush();
      } on Object catch (error) {
        DebugLogger.warning(
          'outbox flush before shutdown failed: $error',
          scope: 'daemon/system',
        );
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

  /// The host's diagnostics export; a host without one says so.
  Future<DiagnosticsExport> exportDiagnostics() async {
    final export = _exportDiagnostics;
    if (export == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'this host exports no diagnostics',
      );
    }
    return export();
  }
}
