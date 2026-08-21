import 'dart:convert';

import 'package:conduit/core/services/secure_credential_storage.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_server_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('document round-trips server credentials', () {
    final source = DirectMcpServersDocument([
      DirectMcpServer(
        id: 'home',
        name: 'Home tools',
        endpoint: 'http://192.168.1.2:3000/mcp?tenant=one',
        bearerToken: 'secret',
        customHeaders: const {'X-Tenant': 'one'},
      ),
    ]).encode();

    final server = DirectMcpServersDocument.decode(source).servers.single;

    expect(server.id, 'home');
    expect(server.bearerToken, 'secret');
    expect(server.customHeaders, {'X-Tenant': 'one'});
  });

  test('document rejects duplicate ids', () {
    final server = DirectMcpServer(
      id: 'duplicate',
      name: 'One',
      endpoint: 'https://example.test/mcp',
    );
    expect(
      () => DirectMcpServersDocument([server, server]),
      throwsFormatException,
    );
  });

  test('validation rejects malformed URLs and headers', () {
    for (final server in [
      DirectMcpServer(
        id: 'bad-url',
        name: 'Bad URL',
        endpoint: 'file:///tmp/mcp',
      ),
      DirectMcpServer(
        id: 'bad-user',
        name: 'Bad user',
        endpoint: 'https://user@example.test/mcp',
      ),
      DirectMcpServer(
        id: 'bad-header',
        name: 'Bad header',
        endpoint: 'https://example.test/mcp',
        customHeaders: const {'Authorization': 'secret'},
      ),
      DirectMcpServer(
        id: 'bad-connection',
        name: 'Bad connection',
        endpoint: 'https://example.test/mcp',
        customHeaders: const {'Connection': 'keep-alive'},
      ),
    ]) {
      expect(server.validate, throwsFormatException);
    }
  });

  test('origin changes clear credentials unless explicitly confirmed', () {
    final previous = DirectMcpServer(
      id: 'server',
      name: 'Server',
      endpoint: 'https://old.example/mcp',
      bearerToken: 'old-secret',
      customHeaders: const {'X-Secret': 'old-header'},
    );
    final next = previous.copyWith(
      endpoint: 'https://new.example/mcp',
      bearerToken: 'new-secret',
      customHeaders: const {'X-Secret': 'new-header'},
    );

    final cleared = DirectMcpServer.secureUpdate(
      previous: previous,
      next: next,
    );
    final confirmed = DirectMcpServer.secureUpdate(
      previous: previous,
      next: next,
      secretsConfirmedForNewOrigin: true,
    );

    expect(cleared.bearerToken, isNull);
    expect(cleared.customHeaders, isEmpty);
    expect(confirmed.bearerToken, 'new-secret');
    expect(confirmed.customHeaders['X-Secret'], 'new-header');
  });

  test(
    'store serializes mutations and persists only secure document',
    () async {
      const platformStorage = FlutterSecureStorage();
      final secure = SecureCredentialStorage(instance: platformStorage);
      final store = DirectMcpServerStore(secure);
      final first = DirectMcpServer(
        id: 'first',
        name: 'First',
        endpoint: 'https://first.example/mcp',
      );
      final second = DirectMcpServer(
        id: 'second',
        name: 'Second',
        endpoint: 'https://second.example/mcp',
      );

      await Future.wait([store.upsert(first), store.upsert(second)]);

      expect((await store.load()).map((server) => server.id), [
        'first',
        'second',
      ]);
      expect(await secure.getDirectMcpServers(), isNotNull);
    },
  );

  test('malformed document failure never logs its payload', () async {
    const secret = 'mcp-document-secret-91a7';
    final source = jsonEncode({
      'version': 1,
      'servers': [
        {
          'schemaVersion': 1,
          'id': 'server',
          'name': 'Server',
          'endpoint': 'file:///$secret',
          'bearerToken': secret,
        },
      ],
    });
    final previousDebugPrint = debugPrint;
    final output = StringBuffer();
    debugPrint = (message, {wrapWidth}) {
      if (message != null) output.writeln(message);
    };

    try {
      expect(
        () => DirectMcpServersDocument.decode(source),
        throwsFormatException,
      );
    } finally {
      debugPrint = previousDebugPrint;
    }

    expect(output.toString(), isNot(contains(secret)));
  });
}
