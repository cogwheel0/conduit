import 'dart:io' show HttpOverrides, SecurityContext, HttpClient;
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/server_config.dart';
import 'server_tls_http_client_factory.dart';

io.Socket createSocketWithOptionalBadCertOverride(
  String base,
  io.OptionBuilder builder,
  ServerConfig serverConfig,
) {
  if (!ServerTlsHttpClientFactory.requiresCustomHttpClient(serverConfig)) {
    return io.io(base, builder.build());
  }

  final target = _tryParseUri(base);
  if (target == null || !(target.scheme == 'https' || target.scheme == 'wss')) {
    return io.io(base, builder.build());
  }

  return HttpOverrides.runWithHttpOverrides<io.Socket>(
    () => io.io(base, builder.build()),
    _ScopedServerTlsOverrides(serverConfig),
  );
}

Uri? _tryParseUri(String url) {
  try {
    final parsed = Uri.parse(url);
    if (parsed.hasScheme) return parsed;
  } catch (_) {}
  return null;
}

class _ScopedServerTlsOverrides extends HttpOverrides {
  _ScopedServerTlsOverrides(this.serverConfig);

  final ServerConfig serverConfig;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return ServerTlsHttpClientFactory.createHttpClient(
      serverConfig,
      fallbackContext: context,
    );
  }
}
