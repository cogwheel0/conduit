import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/network/conduit_user_agent.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

const _headerSecret = 'proxy-custom-header-secret';
const _redirectSecret = 'proxy-reflected-location-secret';

void main() {
  test(
    'health check preserves the Conduit User-Agent across redirects',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final receivedUserAgents = <String?>[];
      server.listen((request) async {
        receivedUserAgents.add(
          request.headers.value(HttpHeaders.userAgentHeader),
        );
        if (request.uri.path == '/health') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/ready');
          await request.response.close();
          return;
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write('{"status":true}');
        await request.response.close();
      });

      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'health-user-agent',
          name: 'Health User-Agent',
          url: 'http://${server.address.address}:${server.port}',
        ),
        workerManager: workerManager,
      );

      try {
        check(await api.checkHealth()).isTrue();
        check(
          receivedUserAgents,
        ).deepEquals([ConduitUserAgent.value, ConduitUserAgent.value]);
      } finally {
        workerManager.dispose();
        await server.close(force: true);
      }
    },
  );

  test(
    'health check keeps its public identity on a cross-origin redirect',
    () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final targetUserAgent = Completer<String?>();
      target.listen((request) async {
        if (!targetUserAgent.isCompleted) {
          targetUserAgent.complete(
            request.headers.value(HttpHeaders.userAgentHeader),
          );
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write('{"status":true}');
        await request.response.close();
      });

      final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      redirect.listen((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://${target.address.address}:${target.port}/ready',
          );
        await request.response.close();
      });

      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'cross-origin-user-agent',
          name: 'Cross-origin User-Agent',
          url: 'http://${redirect.address.address}:${redirect.port}',
        ),
        workerManager: workerManager,
      );

      try {
        check(await api.checkHealth()).isTrue();
        check(
          await targetUserAgent.future.timeout(const Duration(seconds: 5)),
        ).equals(ConduitUserAgent.value);
      } finally {
        workerManager.dispose();
        await redirect.close(force: true);
        await target.close(force: true);
      }
    },
  );

  test('proxy health-check diagnostics never log redirect credentials', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestSeen = Completer<void>();
    server.listen((request) async {
      check(request.uri.path).equals('/health');
      check(request.headers.value('x-proxy-credential')).equals(_headerSecret);
      check(
        request.headers.value(HttpHeaders.userAgentHeader),
      ).equals(ConduitUserAgent.value);
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
        customHeaders: const {
          'x-proxy-credential': _headerSecret,
          'uSeR-aGeNt': 'spoofed-agent',
        },
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
