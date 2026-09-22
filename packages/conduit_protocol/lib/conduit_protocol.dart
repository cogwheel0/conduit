/// The Conduit Core Protocol: the wire contract between the `conduitd`
/// sidecar and the desktop UI.
///
/// Everything here must compile with `dart compile js` — the desktop UI
/// imports it from a browser context. That rules out `dart:io` and anything
/// that reaches it transitively. CI enforces this (WP-0.9); the golden
/// fixtures under `test/` run both natively and as compiled JS so a
/// regression shows up as a failing build, not as a runtime surprise.
library;

export 'src/auth.dart';
export 'src/capabilities.dart';
export 'src/chats.dart';
export 'src/events.dart';
export 'src/handshake.dart';
export 'src/methods.dart';
export 'src/models.dart';
export 'src/peer_helpers.dart';
export 'src/protocol_version.dart';
export 'src/rpc_error.dart';
export 'src/servers.dart';
export 'src/settings.dart';
export 'src/turns.dart';
export 'src/subprotocol.dart';
export 'src/system.dart';
