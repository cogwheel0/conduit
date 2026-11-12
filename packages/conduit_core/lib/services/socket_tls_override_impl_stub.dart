import 'package:socket_io_client/socket_io_client.dart' as io;

import 'package:conduit_core/models/server_config.dart';

/// On the web, socket_io_client polls with its own transport, which can move a
/// session to a WebSocket.
const bool socketPollingCanUpgrade = true;

io.Socket createSocketWithOptionalBadCertOverride(
  String base,
  io.OptionBuilder builder,
  ServerConfig serverConfig,
) {
  // Web and other non-IO platforms: no TLS override possible/needed
  return io.io(base, builder.build());
}
