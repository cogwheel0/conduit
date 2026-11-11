import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';

/// What checking an address for a LibreChat server found.
@immutable
sealed class LibreChatProbeResult {
  const LibreChatProbeResult();
}

/// A LibreChat server answered.
final class LibreChatProbeFound extends LibreChatProbeResult {
  const LibreChatProbeFound(this.server, this.info);

  final LibreChatServer server;
  final LibreChatServerInfo info;
}

/// Something answered, but not LibreChat. [looksLikeOpenWebUi] says when it
/// was Open WebUI, which the app can point the user to instead.
final class LibreChatProbeNotLibreChat extends LibreChatProbeResult {
  const LibreChatProbeNotLibreChat({this.looksLikeOpenWebUi = false});

  final bool looksLikeOpenWebUi;
}

/// Nothing answered, or the address is not usable.
final class LibreChatProbeUnreachable extends LibreChatProbeResult {
  const LibreChatProbeUnreachable(this.error);

  final LibreChatApiException error;
}

/// Checks whether [server] is a LibreChat server and reads how to sign in to
/// it, from its public startup config.
Future<LibreChatProbeResult> probeLibreChatServer(
  LibreChatServer server, {
  HttpClientAdapter? adapter,
  CancelToken? cancelToken,
}) async {
  final client = LibreChatHttpClient(server: server, adapter: adapter);
  try {
    final response = await client.dio.get<dynamic>(
      '/api/config',
      cancelToken: cancelToken,
      options: Options(
        extra: const {LibreChatRequestExtra.authenticate: false},
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    final data = response.data;
    final info = LibreChatServerInfo.fromJson(data);
    if (info != null) return LibreChatProbeFound(server, info);
    return LibreChatProbeNotLibreChat(
      looksLikeOpenWebUi:
          data is Map &&
          data.containsKey('version') &&
          (data['name'] is String || data['features'] is Map),
    );
  } on DioException catch (error) {
    final status = error.response?.statusCode;
    // A busy or failing server says nothing about what it is.
    if (status != null && (status >= 500 || status == 429)) {
      return LibreChatProbeUnreachable(libreChatErrorOf(error));
    }
    if (error.response != null) return const LibreChatProbeNotLibreChat();
    return LibreChatProbeUnreachable(libreChatErrorOf(error));
  } finally {
    client.close();
  }
}
