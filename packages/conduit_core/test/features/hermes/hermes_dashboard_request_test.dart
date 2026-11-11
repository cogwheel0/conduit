import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_json_guard.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

const _chunkSize = 64 * 1024;

/// A gateway answering every request with [status] and a body of [chunks]
/// 64 KiB chunks, counting the chunks it was asked for.
final class _ChunkedGateway implements HttpClientAdapter {
  _ChunkedGateway({
    this.status = 200,
    required this.chunks,
    this.text,
  });

  final int status;
  final int chunks;
  final String? text;
  int sent = 0;

  /// Whether the client cancelled the request.
  bool cancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/api/status') {
      return ResponseBody.fromString(jsonEncode({'auth_required': false}), 200);
    }
    if (text != null) return ResponseBody.fromString(text!, status);
    unawaited(cancelFuture?.then((_) => cancelled = true));
    Stream<Uint8List> body() async* {
      // Like a socket, it stops sending once the request is cancelled.
      for (var i = 0; i < chunks && !cancelled; i++) {
        // As a network would: a chunk at a time, so a reader that stops
        // stops the rest.
        await Future<void>.delayed(Duration.zero);
        sent++;
        yield Uint8List(_chunkSize)..fillRange(0, _chunkSize, 0x61);
      }
    }

    return ResponseBody(body(), status);
  }

  @override
  void close({bool force = false}) {}
}

/// A dashboard reached through its own sign-in, answering [reply].
final class _Bridge implements HermesDashboardBridge {
  _Bridge(this.reply);

  final String reply;

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
    bool urgent = false,
    bool Function()? beforeSend,
  }) async => (status: 200, body: reply);

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async {}
}

HermesDesktopApiService _tokenService(_ChunkedGateway gateway) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopAuthKind: HermesDesktopAuthKind.legacyToken,
      desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
    ),
    dio: Dio()..httpClientAdapter = gateway,
  );
  addTearDown(service.close);
  return service;
}

void main() {
  test('a dashboard answer of any status comes back whole', () async {
    final service = _tokenService(
      _ChunkedGateway(status: 404, chunks: 0, text: '{"detail":"Not Found"}'),
    );
    final response = await service.dashboardRequest('GET', '/api/x');
    check(response.status).equals(404);
    check(response.body).equals('{"detail":"Not Found"}');
  });

  test('a body past the limit is refused before it is all read', () async {
    // 16 MiB on offer, four times the limit.
    final gateway = _ChunkedGateway(
      chunks: 4 * kMaxHermesDesktopFrameBytes ~/ _chunkSize,
    );
    final service = _tokenService(gateway);
    await check(
      service.dashboardRequest('GET', '/api/x'),
    ).throws<HermesResponseTooLargeException>();
    // Stopped at the limit, not after holding the whole body, and the
    // download itself is cancelled rather than read to its end unseen.
    check(gateway.cancelled).isTrue();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    check(gateway.sent).isLessThan(gateway.chunks);
  });

  test('a body through the dashboard sign-in has the limit too', () async {
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
      ),
      dashboardBridgeFactory: ({required root, required accessHeaders}) =>
          _Bridge(jsonEncode('a' * kMaxHermesDesktopFrameCharacters)),
    );
    addTearDown(service.close);
    await check(
      service.dashboardRequest('GET', '/api/x'),
    ).throws<HermesResponseTooLargeException>();
  });
}
