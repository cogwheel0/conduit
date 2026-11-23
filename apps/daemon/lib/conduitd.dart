/// The Conduit desktop sidecar.
///
/// Hosts `conduit_core` in a native Dart process — the one place `dart:io`,
/// `SecurityContext`, raw sockets and streamed Dio responses all work — and
/// exposes it to the desktop app over a loopback JSON-RPC WebSocket.
library;

export 'package:conduit_services/conduit_services.dart';

export 'src/bootstrap.dart';
export 'src/daemon_paths.dart';
export 'src/desktop_core_host.dart';
export 'src/daemon_zone.dart';
export 'src/daemon_server.dart';
export 'src/diagnostics.dart';
export 'src/log.dart';
export 'src/log_file.dart';
export 'src/model_logos.dart';
export 'src/ports/secure_store.dart';
