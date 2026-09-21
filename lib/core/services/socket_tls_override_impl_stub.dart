import 'package:socket_io_client/socket_io_client.dart' as io;

import 'package:conduit_core/models/server_config.dart';

io.Socket createSocketWithOptionalBadCertOverride(
  String base,
  io.OptionBuilder builder,
  ServerConfig serverConfig,
) {
  // Web and other non-IO platforms: no TLS override possible/needed
  return io.io(base, builder.build());
}
