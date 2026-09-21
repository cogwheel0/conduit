import 'package:socket_io_client/socket_io_client.dart' as io;

import 'package:conduit_core/models/server_config.dart';

import 'socket_tls_override_impl_stub.dart'
    if (dart.library.io) 'socket_tls_override_impl_io.dart'
    as impl;

io.Socket createSocketWithOptionalBadCertOverride(
  String base,
  io.OptionBuilder builder,
  ServerConfig serverConfig,
) => impl.createSocketWithOptionalBadCertOverride(base, builder, serverConfig);
