/// Conduit's shared business logic.
///
/// Pure Dart: `dart:io` is allowed (the core does raw-socket health probing,
/// TLS with `SecurityContext`, and a loopback `HttpServer` for MCP OAuth), but
/// Flutter is not. That split is what lets the same engines run inside the
/// mobile app and inside the `conduitd` sidecar.
///
/// It holds the core's logic and its ports — the seams where the core stops
/// and a host platform begins.
library;

/// The models are deliberately *not* re-exported here.
///
/// There are 25 of them with names like `Model`, `User`, `Tool` and `Note`;
/// funnelling those through one barrel would widen the namespace of all 370-odd
/// importers and invite collisions. Import them by path instead —
/// `package:conduit_core/models/chat_message.dart` — which also keeps the
/// mapping from their old `lib/core/models/` location one-to-one.
export 'ports/ports.dart';
export 'src/error/error_message.dart';
