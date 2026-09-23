/// The Conduit desktop sidecar.
///
/// Hosts what will become `conduit_core` in a native Dart process — the one
/// place `dart:io`, `SecurityContext`, raw sockets and streamed Dio responses
/// all work — and exposes it to the Electron renderer over a loopback
/// JSON-RPC WebSocket.
library;

export 'src/auth_service.dart';
export 'src/bootstrap.dart';
export 'src/chats_service.dart';
export 'src/composer_service.dart';
export 'src/prompts_service.dart';
export 'src/core_runtime.dart';
export 'src/daemon_paths.dart';
export 'src/daemon_server.dart';
export 'src/event_bus.dart';
export 'src/log.dart';
export 'src/ports/secure_store.dart';
export 'src/rpc_session.dart';
export 'src/models_service.dart';
export 'src/servers_service.dart';
export 'src/settings_service.dart';
export 'src/system_service.dart';
export 'src/temporary_chats.dart';
export 'src/turns_service.dart';
export 'src/ui_requests_service.dart';
