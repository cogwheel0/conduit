/// The Conduit desktop sidecar.
///
/// Hosts what will become `conduit_core` in a native Dart process — the one
/// place `dart:io`, `SecurityContext`, raw sockets and streamed Dio responses
/// all work — and exposes it to the Electron renderer over a loopback
/// JSON-RPC WebSocket.
library;

export 'src/bootstrap.dart';
export 'src/daemon_paths.dart';
export 'src/daemon_server.dart';
export 'src/event_bus.dart';
export 'src/log.dart';
export 'src/rpc_session.dart';
export 'src/system_service.dart';
