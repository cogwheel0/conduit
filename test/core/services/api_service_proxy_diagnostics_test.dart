import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

const _headerSecret = 'proxy-custom-header-secret';
const _redirectSecret = 'proxy-reflected-location-secret';

void main() {
  test('proxy health-check diagnostics never log redirect credentials', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestSeen = Completer<void>();
    server.listen((request) async {
      check(request.uri.path).equals('/health');
      check(request.headers.value('x-proxy-credential')).equals(_headerSecret);
      if (!requestSeen.isCompleted) requestSeen.complete();
      request.response
        ..statusCode = HttpStatus.temporaryRedirect
        ..headers.set(
          HttpHeaders.locationHeader,
          'https://example.test/login?credential=$_redirectSecret&reflected=$_headerSecret',
        );
      await request.response.close();
    });

    final api = ApiService(
      serverConfig: ServerConfig(
        id: 'proxy-diagnostics',
        name: 'Proxy diagnostics',
        url: 'http://${server.address.address}:${server.port}',
        customHeaders: const {'x-proxy-credential': _headerSecret},
      ),
      workerManager: WorkerManager(),
    );

    final previousDebugPrint = debugPrint;
    final output = StringBuffer();
    debugPrint = (message, {wrapWidth}) {
      if (message != null) output.writeln(message);
    };

    try {
      final result = await api.checkHealthWithProxyDetection();
      check(result).equals(HealthCheckResult.proxyAuthRequired);
      await requestSeen.future;
    } finally {
      debugPrint = previousDebugPrint;
      await server.close(force: true);
    }

    final logs = output.toString();
    check(logs).contains('proxy-auth-redirect-detected');
    check(logs).contains('statusCode=307');
    check(logs).not((value) => value.contains(_headerSecret));
    check(logs).not((value) => value.contains(_redirectSecret));
  });
}
