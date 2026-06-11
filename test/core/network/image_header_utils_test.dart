import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/network/image_header_utils.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('imageUrlIsServerOrigin', () {
    test('returns true for same host absolute URL', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com',
          'https://openwebui.example.com/static/image.png',
        ),
      ).isTrue();
    });

    test('returns false for same host with different port', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com:443',
          'https://openwebui.example.com:8443/static/image.png',
        ),
      ).isFalse();
    });

    test('returns true for same origin with implicit default port', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com:443',
          'https://openwebui.example.com/static/image.png',
        ),
      ).isTrue();
    });

    test('returns false for same host with different scheme', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com',
          'http://openwebui.example.com/static/image.png',
        ),
      ).isFalse();
    });

    test('returns false for cross-origin absolute URL', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com',
          'https://attacker.example.net/static/image.png',
        ),
      ).isFalse();
    });

    test('returns true for relative path', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com',
          '/static/image.png',
        ),
      ).isTrue();
    });

    test('returns false for null server base URL', () {
      check(imageUrlIsServerOrigin(null, '/static/image.png')).isFalse();
    });

    test('returns false for empty server base URL', () {
      check(imageUrlIsServerOrigin('', '/static/image.png')).isFalse();
    });

    test('returns false for malformed URL', () {
      check(
        imageUrlIsServerOrigin('https://openwebui.example.com', 'http://[::1'),
      ).isFalse();
    });

    test('returns false for absolute non-network URL', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com',
          'data:application/pdf;base64,AA==',
        ),
      ).isFalse();
    });
  });

  group('buildImageHeadersForUrlFromContainer', () {
    ProviderContainer buildContainer({String? token = 'token'}) {
      final workerManager = WorkerManager(debugIsWebOverride: true);
      addTearDown(workerManager.dispose);
      final api = ApiService(
        serverConfig: const ServerConfig(
          id: 'server-1',
          name: 'Open WebUI',
          url: 'https://openwebui.example.com',
          apiKey: 'api-key',
          customHeaders: {'X-Custom': 'value'},
        ),
        workerManager: workerManager,
      );
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          authTokenProvider3.overrideWithValue(token),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('returns auth and custom headers for same-origin URLs', () {
      final container = buildContainer();

      final headers = buildImageHeadersForUrlFromContainer(
        container,
        'https://openwebui.example.com/static/image.png',
      );

      check(headers).isNotNull().deepEquals({
        'Authorization': 'Bearer token',
        'X-Custom': 'value',
      });
    });

    test('returns null for cross-origin URLs', () {
      final container = buildContainer();

      final headers = buildImageHeadersForUrlFromContainer(
        container,
        'https://attacker.example.net/pixel.png',
      );

      check(headers).isNull();
    });

    test('falls back to api key for same-origin URLs without token', () {
      final container = buildContainer(token: null);

      final headers = buildImageHeadersForUrlFromContainer(
        container,
        '/static/image.png',
      );

      check(headers).isNotNull().deepEquals({
        'Authorization': 'Bearer api-key',
        'X-Custom': 'value',
      });
    });
  });
}
