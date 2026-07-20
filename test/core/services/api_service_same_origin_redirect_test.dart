import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isCredentialSafeRedirectTarget', () {
    test('accepts the exact origin and normalized default ports', () {
      check(
        isCredentialSafeRedirectTarget(
          Uri.parse('https://server.example/api/config'),
          Uri.parse('https://server.example:443/api/config/'),
        ),
      ).isTrue();
      check(
        isCredentialSafeRedirectTarget(
          Uri.parse('http://server.example:8080/api/config'),
          Uri.parse('http://server.example:8080/api/v1/chats/'),
        ),
      ).isTrue();
    });

    test('accepts a default-port https upgrade only', () {
      check(
        isCredentialSafeRedirectTarget(
          Uri.parse('http://server.example/api/config'),
          Uri.parse('https://server.example/api/config'),
        ),
      ).isTrue();
      check(
        isCredentialSafeRedirectTarget(
          Uri.parse('http://server.example:8080/api/config'),
          Uri.parse('https://server.example:8443/api/config'),
        ),
      ).isFalse();
    });

    test('rejects host changes, downgrades, and port remaps', () {
      check(
        isCredentialSafeRedirectTarget(
          Uri.parse('https://server.example/api/config'),
          Uri.parse('https://evil.example/api/config'),
        ),
      ).isFalse();
      check(
        isCredentialSafeRedirectTarget(
          Uri.parse('https://server.example/api/config'),
          Uri.parse('http://server.example/api/config'),
        ),
      ).isFalse();
      check(
        isCredentialSafeRedirectTarget(
          Uri.parse('https://server.example/api/config'),
          Uri.parse('https://server.example:8443/api/config'),
        ),
      ).isFalse();
    });
  });

  group('same-origin redirect recovery', () {
    late HttpServer server;
    late WorkerManager workerManager;
    late ApiService api;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      workerManager = WorkerManager(debugIsWebOverride: true);
      api = ApiService(
        serverConfig: ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'http://${server.address.address}:${server.port}',
        ),
        workerManager: workerManager,
        authToken: 'session-token',
      );
    });

    tearDown(() async {
      api.dispose();
      workerManager.dispose();
      await server.close(force: true);
    });

    test('follows a same-origin 301 for GET and keeps credentials', () async {
      final seenAuthByPath = <String, String?>{};
      server.listen((request) async {
        seenAuthByPath[request.uri.path] =
            request.headers.value(HttpHeaders.authorizationHeader);
        if (request.uri.path == '/api/config') {
          request.response.statusCode = HttpStatus.movedPermanently;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/api/config/',
          );
        } else {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"ok":true}');
        }
        await request.response.close();
      });

      final response = await api.dio.get<Map<String, dynamic>>('/api/config');
      check(response.statusCode).equals(200);
      check(response.data).isNotNull();
      check(seenAuthByPath['/api/config/']).equals('Bearer session-token');
    });

    test('converts a 303 POST into a GET of the target', () async {
      final methodsByPath = <String, String>{};
      server.listen((request) async {
        methodsByPath[request.uri.path] = request.method;
        if (request.uri.path == '/submit') {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.seeOther;
          request.response.headers.set(HttpHeaders.locationHeader, '/result');
        } else {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"ok":true}');
        }
        await request.response.close();
      });

      final response = await api.dio.post<Map<String, dynamic>>(
        '/submit',
        data: {'value': 1},
      );
      check(response.statusCode).equals(200);
      check(methodsByPath['/result']).equals('GET');
    });

    test('surfaces a non-303 POST redirect instead of following it', () async {
      var followUps = 0;
      server.listen((request) async {
        if (request.uri.path == '/submit') {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.temporaryRedirect;
          request.response.headers.set(HttpHeaders.locationHeader, '/other');
        } else {
          followUps++;
          request.response.statusCode = HttpStatus.ok;
        }
        await request.response.close();
      });

      await check(
        api.dio.post<void>('/submit', data: {'value': 1}),
      ).throws<Exception>();
      check(followUps).equals(0);
    });

    test('gives up after the redirect hop budget', () async {
      var hits = 0;
      server.listen((request) async {
        hits++;
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/loop/${request.uri.pathSegments.length}',
        );
        await request.response.close();
      });

      await check(api.dio.get<void>('/loop')).throws<Exception>();
      // Initial request plus at most five replayed hops.
      check(hits).isLessOrEqual(6);
    });
  });
}
