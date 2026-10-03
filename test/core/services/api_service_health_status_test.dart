import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_test/flutter_test.dart';

Future<HealthCheckResult> _probe(int status) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write('{"detail":"Not Found"}');
    await request.response.close();
  });
  final api = ApiService(
    serverConfig: ServerConfig(
      id: 'health-status',
      name: 'Health status',
      url: 'http://${server.address.address}:${server.port}',
    ),
    workerManager: WorkerManager(),
  );
  addTearDown(api.dispose);
  return api.checkHealthWithProxyDetection(throwOnConnectionError: true);
}

void main() {
  // B-03: a reachable server without Open WebUI's /health route was reported
  // as temporarily unavailable instead of not being Open WebUI.
  test('a 404 on /health means the server is not Open WebUI', () async {
    check(await _probe(404)).equals(HealthCheckResult.notOpenWebUI);
  });

  test('a 503 on /health still means temporarily unavailable', () async {
    check(await _probe(503)).equals(HealthCheckResult.unhealthy);
  });
}
