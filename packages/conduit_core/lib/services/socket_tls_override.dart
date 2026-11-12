import 'package:socket_io_client/socket_io_client.dart' as io;

import 'package:conduit_core/models/server_config.dart';

import 'socket_tls_override_impl_stub.dart'
    if (dart.library.io) 'socket_tls_override_impl_io.dart'
    as impl;

/// Whether a Socket.IO session that starts on HTTP polling can upgrade to a
/// WebSocket on this platform. Not on native platforms, where it stays on
/// polling, so a client there must not ask for an upgrade.
const bool socketPollingCanUpgrade = impl.socketPollingCanUpgrade;

io.Socket createSocketWithOptionalBadCertOverride(
  String base,
  io.OptionBuilder builder,
  ServerConfig serverConfig,
) => impl.createSocketWithOptionalBadCertOverride(base, builder, serverConfig);
