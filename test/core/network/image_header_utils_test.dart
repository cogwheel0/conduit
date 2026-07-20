import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/network/conduit_user_agent.dart';
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
    ProviderContainer buildContainer({
      String? token = 'token',
      Map<String, String> customHeaders = const {'X-Custom': 'value'},
      bool suppressCookieCustomHeader = false,
    }) {
      final workerManager = WorkerManager(debugIsWebOverride: true);
      addTearDown(workerManager.dispose);
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'server-1',
          name: 'Open WebUI',
          url: 'https://openwebui.example.com',
          apiKey: 'api-key',
          customHeaders: customHeaders,
        ),
        workerManager: workerManager,
        suppressCookieCustomHeader: suppressCookieCustomHeader,
      );
      addTearDown(api.dispose);
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
        ConduitUserAgent.headerName: ConduitUserAgent.value,
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

    test('filters custom Authorization without regard to casing', () {
      final container = buildContainer(
        customHeaders: const {
          'aUtHoRiZaTiOn': 'Bearer stale-config-token',
          'X-Custom': 'value',
        },
      );

      final headers = buildImageHeadersForUrlFromContainer(
        container,
        '/static/image.png',
      );

      check(headers).isNotNull().deepEquals({
        'Authorization': 'Bearer token',
        'X-Custom': 'value',
        ConduitUserAgent.headerName: ConduitUserAgent.value,
      });
    });

    test('filters configured Cookie while the logout fence is active', () {
      final container = buildContainer(
        customHeaders: const {
          'cOoKiE': 'proxy_session=stale',
          'X-Custom': 'value',
        },
        suppressCookieCustomHeader: true,
      );

      final headers = buildImageHeadersForUrlFromContainer(
        container,
        '/static/image.png',
      );

      check(headers).isNotNull().deepEquals({
        'Authorization': 'Bearer token',
        'X-Custom': 'value',
        ConduitUserAgent.headerName: ConduitUserAgent.value,
      });
    });

    test('never revives a legacy config API key without an auth token', () {
      final container = buildContainer(token: null);

      final headers = buildImageHeadersForUrlFromContainer(
        container,
        '/static/image.png',
      );

      check(headers).isNotNull().deepEquals({
        'X-Custom': 'value',
        ConduitUserAgent.headerName: ConduitUserAgent.value,
      });
    });

    test('returns no auth headers when API ownership is unavailable', () {
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          authTokenProvider3.overrideWithValue('must-not-escape'),
        ],
      );
      addTearDown(container.dispose);

      check(
        buildImageHeadersForUrlFromContainer(container, '/static/image.png'),
      ).isNull();
    });
  });

  ApiService buildKeyedApi({
    String id = 'server-1',
    String url = 'https://openwebui.example.com',
    String? authToken,
  }) {
    final workerManager = WorkerManager(debugIsWebOverride: true);
    addTearDown(workerManager.dispose);
    final api = ApiService(
      serverConfig: ServerConfig(id: id, name: 'Open WebUI', url: url),
      workerManager: workerManager,
      authToken: authToken,
    );
    addTearDown(api.dispose);
    return api;
  }

  test('same server image URL keeps an opaque key stable across auth-epoch '
      'object churn', () {
    final api = buildKeyedApi(authToken: 'account-a-token');
    const imageUrl = 'https://openwebui.example.com/api/v1/files/same/content';
    final epochA = Object();
    final epochB = Object();

    final keyA = buildSessionScopedImageCacheKey(
      api: api,
      authSessionEpoch: epochA,
      url: imageUrl,
    );
    final keyAAgain = buildSessionScopedImageCacheKey(
      api: api,
      authSessionEpoch: epochA,
      url: imageUrl,
    );
    // A rebuilt epoch object with an unchanged account/server (mid-session
    // provider churn) must not rotate the persistent disk key.
    final keyB = buildSessionScopedImageCacheKey(
      api: api,
      authSessionEpoch: epochB,
      url: imageUrl,
    );

    expect(keyA, isNotNull);
    expect(keyAAgain, keyA);
    expect(keyB, keyA);
    expect(keyA, isNot(contains(imageUrl)));
    expect(keyA, isNot(contains('account-a-token')));
    check(
      buildSessionScopedImageCacheKey(
        api: api,
        authSessionEpoch: epochA,
        url: 'https://cdn.example.net/public.png',
      ),
    ).isNull();
  });

  test('the same logical owner gets identical keys across process restarts '
      '(fresh objects, same server and token)', () {
    // Two independent ApiService/epoch objects with the same persisted server
    // config and auth token model a restarted process: the disk cache entry
    // written before the restart must resolve to the same key afterwards.
    final apiA = buildKeyedApi(authToken: 'account-a-token');
    final apiB = buildKeyedApi(authToken: 'account-a-token');
    const imageUrl = 'https://openwebui.example.com/api/v1/files/a/content';

    final keyA = buildSessionScopedImageCacheKey(
      api: apiA,
      authSessionEpoch: Object(),
      url: imageUrl,
    );
    final keyB = buildSessionScopedImageCacheKey(
      api: apiB,
      authSessionEpoch: Object(),
      url: imageUrl,
    );

    expect(keyA, isNotNull);
    expect(keyB, keyA);
  });

  test('different accounts and different servers never share cache keys', () {
    const imageUrl = 'https://openwebui.example.com/api/v1/files/a/content';
    final accountA = buildKeyedApi(authToken: 'account-a-token');
    final accountB = buildKeyedApi(authToken: 'account-b-token');
    final unauthenticated = buildKeyedApi();
    final otherServer = buildKeyedApi(
      id: 'server-2',
      url: 'https://openwebui.example.com',
      authToken: 'account-a-token',
    );

    final keyA = buildSessionScopedImageCacheKey(
      api: accountA,
      authSessionEpoch: Object(),
      url: imageUrl,
    );
    final keyB = buildSessionScopedImageCacheKey(
      api: accountB,
      authSessionEpoch: Object(),
      url: imageUrl,
    );
    final keyAnon = buildSessionScopedImageCacheKey(
      api: unauthenticated,
      authSessionEpoch: Object(),
      url: imageUrl,
    );
    final keyOtherServer = buildSessionScopedImageCacheKey(
      api: otherServer,
      authSessionEpoch: Object(),
      url: imageUrl,
    );

    expect(keyA, isNotNull);
    expect(keyB, isNot(keyA));
    expect(keyAnon, isNot(keyA));
    expect(keyAnon, isNot(keyB));
    expect(keyOtherServer, isNot(keyA));
    expect(keyA, isNot(contains('account-a-token')));
    expect(keyB, isNot(contains('account-b-token')));
  });

  test('effective image headers participate through an opaque stable hash', () {
    final workerManager = WorkerManager(debugIsWebOverride: true);
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server-1',
        name: 'Open WebUI',
        url: 'https://openwebui.example.com',
      ),
      workerManager: workerManager,
    );
    addTearDown(() {
      api.dispose();
      workerManager.dispose();
    });
    final epoch = Object();
    const imageUrl = 'https://openwebui.example.com/api/v1/files/a/content';
    const secretA = 'Bearer account-a-secret';
    const secretB = 'Bearer account-b-secret';

    final keyA = buildSessionScopedImageCacheKey(
      api: api,
      authSessionEpoch: epoch,
      url: imageUrl,
      effectiveHeaders: const <String, String>{
        'Authorization': secretA,
        'X-Tenant': 'tenant-a',
      },
    );
    final keyAReordered = buildSessionScopedImageCacheKey(
      api: api,
      authSessionEpoch: epoch,
      url: imageUrl,
      effectiveHeaders: const <String, String>{
        'x-tenant': 'tenant-a',
        'authorization': secretA,
      },
    );
    final keyB = buildSessionScopedImageCacheKey(
      api: api,
      authSessionEpoch: epoch,
      url: imageUrl,
      effectiveHeaders: const <String, String>{
        'Authorization': secretB,
        'X-Tenant': 'tenant-b',
      },
    );

    expect(keyA, keyAReordered);
    expect(keyB, isNot(keyA));
    expect(keyA, isNot(contains(secretA)));
    expect(keyB, isNot(contains(secretB)));
    expect(keyA, isNot(contains('tenant-a')));
  });

  test(
    'explicit cross-origin headers never share the public URL cache key',
    () {
      final workerManager = WorkerManager(debugIsWebOverride: true);
      final api = ApiService(
        serverConfig: const ServerConfig(
          id: 'server-1',
          name: 'Open WebUI',
          url: 'https://openwebui.example.com',
        ),
        workerManager: workerManager,
      );
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          authTokenProvider3.overrideWithValue('account-token'),
          openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        ],
      );
      addTearDown(() {
        container.dispose();
        api.dispose();
        workerManager.dispose();
      });
      const url = 'https://cdn.example.test/private.png';
      const secret = 'tenant-secret-value';

      final first = buildImageCacheKeyForUrlFromContainer(
        container,
        url,
        effectiveHeaders: const {'X-Tenant': secret},
      );
      final second = buildImageCacheKeyForUrlFromContainer(
        container,
        url,
        effectiveHeaders: const {'X-Tenant': 'another-tenant'},
      );

      expect(first, isNotNull);
      expect(first, isNot(url));
      expect(first, isNot(contains(secret)));
      expect(second, isNot(first));
      expect(buildImageCacheKeyForUrlFromContainer(container, url), isNull);
    },
  );

  test('missing API ownership uses a one-shot opaque cache key', () {
    const imageUrl = '/api/v1/files/owner-unavailable/content';
    final epoch = Object();

    final first = buildSessionScopedImageCacheKey(
      api: null,
      authSessionEpoch: epoch,
      url: imageUrl,
    );
    final second = buildSessionScopedImageCacheKey(
      api: null,
      authSessionEpoch: epoch,
      url: imageUrl,
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first, isNot(imageUrl));
    expect(first, isNot(contains(imageUrl)));
    expect(second, isNot(first));
  });

  test('ownership failure never falls back to a URL-shared cache key', () {
    final workerManager = WorkerManager(debugIsWebOverride: true);
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server-1',
        name: 'Open WebUI',
        url: 'https://openwebui.example.com',
      ),
      workerManager: workerManager,
    );
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        authTokenProvider3.overrideWithValue('account-token'),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => throw StateError('ownership unavailable'),
        ),
      ],
    );
    addTearDown(() {
      container.dispose();
      api.dispose();
      workerManager.dispose();
    });
    const imageUrl =
        'https://openwebui.example.com/api/v1/files/shared/content';

    expect(
      buildImageHeadersForUrlFromContainer(container, imageUrl),
      containsPair('Authorization', 'Bearer account-token'),
    );
    final firstKey = buildImageCacheKeyForUrlFromContainer(container, imageUrl);
    final secondKey = buildImageCacheKeyForUrlFromContainer(
      container,
      imageUrl,
    );

    expect(firstKey, isNotNull);
    expect(secondKey, isNotNull);
    expect(firstKey, isNot(imageUrl));
    expect(firstKey, isNot(contains(imageUrl)));
    expect(secondKey, isNot(firstKey));
  });
}
