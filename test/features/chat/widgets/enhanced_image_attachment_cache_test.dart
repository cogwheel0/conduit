import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:conduit/core/network/conduit_user_agent.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/image_attachment_cache_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart'
    show
        debugDecodeCachedResolvedImageAttachment,
        debugDecodeCachedResolvedImageAttachmentError,
        debugLoadImageAttachmentError,
        debugMergeImageHeaders;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(debugResetImageAttachmentCaches);
  tearDown(debugResetImageAttachmentCaches);

  test('same-origin image metadata cannot override the Conduit identity', () {
    final headers = debugMergeImageHeaders(
      {
        'Authorization': 'Bearer token',
        ConduitUserAgent.headerName: ConduitUserAgent.value,
      },
      const {'uSeR-aGeNt': 'spoofed-agent', 'X-Image': 'value'},
    );

    expect(headers, {
      'Authorization': 'Bearer token',
      'X-Image': 'value',
      ConduitUserAgent.headerName: ConduitUserAgent.value,
    });
  });

  test('resolved image cache evicts the least recently used entry', () {
    final scope = ImageAttachmentCacheScope(
      api: null,
      authSessionEpoch: Object(),
    );
    for (var index = 0; index < 80; index += 1) {
      debugSeedResolvedImageAttachment(
        'image-$index',
        'data:image/png;base64,AA==',
        scope: scope,
      );
    }

    expect(debugResolvedImageAttachmentCount(), 80);

    debugSeedResolvedImageAttachment(
      'image-0',
      'data:image/png;base64,AA==',
      scope: scope,
    );
    debugSeedResolvedImageAttachment(
      'image-80',
      'data:image/png;base64,AA==',
      scope: scope,
    );

    expect(debugResolvedImageAttachmentCount(), 80);
    expect(debugHasResolvedImageAttachment('image-0', scope: scope), isTrue);
    expect(debugHasResolvedImageAttachment('image-1', scope: scope), isFalse);
    expect(debugHasResolvedImageAttachment('image-80', scope: scope), isTrue);
  });

  test(
    'decoded image cache evicts by retained bytes, not only entry count',
    () {
      final scope = ImageAttachmentCacheScope(
        api: null,
        authSessionEpoch: Object(),
      );
      final budget = debugDecodedImageAttachmentByteBudget;
      final payloadSize = (budget ~/ 2) + 1;

      preCacheImageBytes('first', Uint8List(payloadSize), scope: scope);
      check(debugHasDecodedImageAttachment('first', scope: scope)).isTrue();
      preCacheImageBytes('second', Uint8List(payloadSize), scope: scope);

      check(debugHasDecodedImageAttachment('first', scope: scope)).isFalse();
      check(debugHasDecodedImageAttachment('second', scope: scope)).isTrue();
      check(debugDecodedImageAttachmentCount()).equals(1);
      check(debugDecodedImageAttachmentWeight()).isLessOrEqual(budget);
    },
  );

  test('large inline payloads are not retained again as cache keys', () {
    final inlinePayload =
        'data:image/png;base64,${List<String>.filled(9 * 1024, 'A').join()}';

    preCacheImageBytes(inlinePayload, Uint8List(64));

    check(debugHasDecodedImageAttachment(inlinePayload)).isFalse();
    check(debugDecodedImageAttachmentCount()).equals(0);
  });

  test('SVG URL detection ignores fragments and inspects URI query data', () {
    check(
      imageAttachmentUrlIsSvg('https://example.test/icon.svg#dark-symbol'),
    ).isTrue();
    check(
      imageAttachmentUrlIsSvg(
        'https://example.test/render?format=image/svg+xml#preview',
      ),
    ).isTrue();
    check(
      imageAttachmentUrlIsSvg(
        'https://example.test/render?format=image%2Fsvg%2Bxml#preview',
      ),
    ).isTrue();
    check(
      imageAttachmentUrlIsSvg('https://example.test/icon.png#fallback.svg'),
    ).isFalse();
  });

  test('core cache deduplicates concurrent loads for the same owner', () async {
    final scope = ImageAttachmentCacheScope(
      api: null,
      authSessionEpoch: Object(),
    );
    final loadResult = Completer<ImageAttachmentCacheEntry>();
    var loadCalls = 0;

    Future<ImageAttachmentCacheEntry> load(ImageAttachmentCacheEntry? cached) {
      loadCalls += 1;
      check(cached).isNull();
      return loadResult.future;
    }

    final first = imageAttachmentCacheStore.load(
      'owned-file',
      scope: scope,
      loader: load,
    );
    final second = imageAttachmentCacheStore.load(
      'owned-file',
      scope: scope,
      loader: load,
    );

    check(identical(first, second)).isTrue();
    check(loadCalls).equals(1);
    loadResult.complete(
      const ImageAttachmentCacheEntry(
        resolvedData: 'https://example.test/image.png',
        isSvg: false,
      ),
    );
    await Future.wait([first, second]);
  });

  test(
    'in-flight deduplication is not evicted under request pressure',
    () async {
      final scope = ImageAttachmentCacheScope(
        api: null,
        authSessionEpoch: Object(),
      );
      final completions = List<Completer<ImageAttachmentCacheEntry>>.generate(
        25,
        (_) => Completer<ImageAttachmentCacheEntry>(),
      );
      var loadCalls = 0;
      final loads = <Future<ImageAttachmentCacheEntry>>[];

      for (var index = 0; index < completions.length; index += 1) {
        loads.add(
          imageAttachmentCacheStore.load(
            'owned-file-$index',
            scope: scope,
            loader: (_) {
              loadCalls += 1;
              return completions[index].future;
            },
          ),
        );
      }
      final duplicate = imageAttachmentCacheStore.load(
        'owned-file-0',
        scope: scope,
        loader: (_) {
          loadCalls += 1;
          return Future<ImageAttachmentCacheEntry>.value(
            const ImageAttachmentCacheEntry(isSvg: false),
          );
        },
      );

      check(identical(duplicate, loads.first)).isTrue();
      check(loadCalls).equals(25);
      for (final completion in completions) {
        completion.complete(const ImageAttachmentCacheEntry(isSvg: false));
      }
      await Future.wait([...loads, duplicate]);
    },
  );

  test(
    'a pre-clear literal load cannot return or overwrite stale bytes',
    () async {
      const attachmentId = 'https://cdn.example.test/replaced.png';
      final releaseOldLoad = Completer<void>();
      final oldLoad = imageAttachmentCacheStore.load(
        attachmentId,
        loader: (_) async {
          await releaseOldLoad.future;
          final bytes = Uint8List.fromList(const [1]);
          imageAttachmentCacheStore.cacheBytes(attachmentId, bytes);
          return ImageAttachmentCacheEntry(bytes: bytes, isSvg: false);
        },
      );

      imageAttachmentCacheStore.clear();
      await imageAttachmentCacheStore.load(
        attachmentId,
        loader: (_) async {
          final bytes = Uint8List.fromList(const [9]);
          imageAttachmentCacheStore.cacheBytes(attachmentId, bytes);
          return ImageAttachmentCacheEntry(bytes: bytes, isSvg: false);
        },
      );
      releaseOldLoad.complete();
      await check(oldLoad).throws<StateError>();

      check(
        imageAttachmentCacheStore.read(attachmentId)!.bytes!.toList(),
      ).deepEquals([9]);
    },
  );

  test('an invalidated account scope cannot repopulate after clear', () {
    const attachmentId = 'server-file';
    final oldEpoch = Object();
    final oldScope = ImageAttachmentCacheScope(
      api: null,
      authSessionEpoch: oldEpoch,
    );
    imageAttachmentCacheStore.cacheBytes(
      attachmentId,
      Uint8List.fromList(const [1]),
      scope: oldScope,
    );

    imageAttachmentCacheStore.clear(invalidatedAuthSessionEpoch: oldEpoch);
    imageAttachmentCacheStore.cacheBytes(
      attachmentId,
      Uint8List.fromList(const [2]),
      scope: oldScope,
    );
    check(
      imageAttachmentCacheStore.read(attachmentId, scope: oldScope),
    ).isNull();

    final newScope = ImageAttachmentCacheScope(
      api: null,
      authSessionEpoch: Object(),
    );
    imageAttachmentCacheStore.cacheBytes(
      attachmentId,
      Uint8List.fromList(const [3]),
      scope: newScope,
    );
    check(
      imageAttachmentCacheStore
          .read(attachmentId, scope: newScope)!
          .bytes!
          .toList(),
    ).deepEquals([3]);
  });

  test(
    'account-scoped attachments bypass every cache surface without an owner',
    () async {
      const attachmentId = 'unowned-server-file';
      var loadCalls = 0;

      preCacheImageBytes(attachmentId, Uint8List.fromList(const [1, 2, 3]));
      imageAttachmentCacheStore
        ..cacheResolvedData(
          attachmentId,
          'data:image/png;base64,AQ==',
          isSvg: false,
        )
        ..cacheError(attachmentId, 'must not persist');

      Future<ImageAttachmentCacheEntry> load(
        ImageAttachmentCacheEntry? cached,
      ) async {
        loadCalls += 1;
        check(cached).isNull();
        return const ImageAttachmentCacheEntry(
          resolvedData: 'https://example.test/image.png',
          isSvg: false,
        );
      }

      final first = imageAttachmentCacheStore.load(attachmentId, loader: load);
      final second = imageAttachmentCacheStore.load(attachmentId, loader: load);

      check(identical(first, second)).isFalse();
      await Future.wait([first, second]);
      check(loadCalls).equals(2);
      check(imageAttachmentCacheStore.read(attachmentId)).isNull();
      check(debugHasResolvedImageAttachment(attachmentId)).isFalse();
      check(debugHasDecodedImageAttachment(attachmentId)).isFalse();
      check(debugHasImageAttachmentError(attachmentId)).isFalse();
    },
  );

  test('literal image sources remain cacheable without an account owner', () {
    const attachmentId = 'https://cdn.example.test/public.png';
    preCacheImageBytes(attachmentId, Uint8List.fromList(const [4, 5, 6]));

    check(debugHasDecodedImageAttachment(attachmentId)).isTrue();
  });

  test('server file cache bytes and errors are isolated by API owner', () {
    final workerA = WorkerManager(maxConcurrentTasks: 1);
    final workerB = WorkerManager(maxConcurrentTasks: 1);
    final apiA = ApiService(
      serverConfig: const ServerConfig(
        id: 'server-a',
        name: 'Server A',
        url: 'https://a.example.test',
      ),
      workerManager: workerA,
    );
    final apiB = ApiService(
      serverConfig: const ServerConfig(
        id: 'server-b',
        name: 'Server B',
        url: 'https://b.example.test',
      ),
      workerManager: workerB,
    );
    addTearDown(() {
      apiA.dispose();
      apiB.dispose();
      workerA.dispose();
      workerB.dispose();
    });
    final epoch = Object();
    final scopeA = ImageAttachmentCacheScope(
      api: apiA,
      authSessionEpoch: epoch,
    );
    final scopeB = ImageAttachmentCacheScope(
      api: apiB,
      authSessionEpoch: epoch,
    );
    const attachmentId = 'same-server-file-id';

    preCacheImageBytes(
      attachmentId,
      Uint8List.fromList(const [1, 2, 3]),
      scope: scopeA,
    );

    check(debugHasDecodedImageAttachment(attachmentId, scope: scopeA)).isTrue();
    check(
      debugHasDecodedImageAttachment(attachmentId, scope: scopeB),
    ).isFalse();

    debugSeedImageAttachmentError(
      attachmentId,
      'account A only',
      scope: scopeA,
    );

    check(debugHasImageAttachmentError(attachmentId, scope: scopeA)).isTrue();
    check(debugHasImageAttachmentError(attachmentId, scope: scopeB)).isFalse();
  });

  test(
    'authentication ownership transition clears retained image data',
    () async {
      final epochs = NotifierProvider<_EpochNotifier, Object>(
        () => _EpochNotifier(Object()),
      );
      final container = ProviderContainer(
        overrides: [
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(epochs),
          ),
        ],
      );
      addTearDown(container.dispose);
      final lifecycle = container.listen<void>(
        imageAttachmentCacheLifecycleProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(lifecycle.close);
      final initialScope = ImageAttachmentCacheScope(
        api: null,
        authSessionEpoch: container.read(epochs),
      );
      preCacheImageBytes(
        'owned-file',
        Uint8List.fromList(const [1]),
        scope: initialScope,
      );
      check(debugDecodedImageAttachmentCount()).equals(1);

      container.read(epochs.notifier).replace(Object());
      await Future<void>.delayed(Duration.zero);

      check(debugDecodedImageAttachmentCount()).equals(0);
    },
  );

  test(
    'cached resolved image data decodes without refetching through the api',
    () async {
      final workerManager = WorkerManager(maxConcurrentTasks: 1);
      addTearDown(workerManager.dispose);
      const attachmentId = 'cached-image';
      final scope = ImageAttachmentCacheScope(
        api: null,
        authSessionEpoch: Object(),
      );
      const pngDataUrl =
          'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF9sAAAAASUVORK5CYII=';

      debugSeedResolvedImageAttachment(attachmentId, pngDataUrl, scope: scope);
      expect(
        debugHasDecodedImageAttachment(attachmentId, scope: scope),
        isFalse,
      );

      await debugDecodeCachedResolvedImageAttachment(
        attachmentId: attachmentId,
        workerManager: workerManager,
        scope: scope,
      );

      expect(
        debugHasDecodedImageAttachment(attachmentId, scope: scope),
        isTrue,
      );
    },
  );

  test(
    'invalid cached image data maps to the localized decode error',
    () async {
      final workerManager = WorkerManager(maxConcurrentTasks: 1);
      addTearDown(workerManager.dispose);
      const attachmentId = 'invalid-image';
      final scope = ImageAttachmentCacheScope(
        api: null,
        authSessionEpoch: Object(),
      );
      debugSeedResolvedImageAttachment(
        attachmentId,
        'data:image/png;base64',
        scope: scope,
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      final error = await debugDecodeCachedResolvedImageAttachmentError(
        attachmentId: attachmentId,
        workerManager: workerManager,
        l10n: l10n,
        scope: scope,
      );

      expect(error, l10n.failedToDecodeImage);
    },
  );

  test(
    'invalid image loads fail closed without leaking async cleanup errors',
    () async {
      final workerManager = WorkerManager(maxConcurrentTasks: 1);
      addTearDown(workerManager.dispose);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final zoneErrors = <Object>[];
      String? error;

      await runZonedGuarded(
        () async {
          error = await debugLoadImageAttachmentError(
            attachmentId: 'data:image/png;base64',
            workerManager: workerManager,
            l10n: l10n,
          );
          await Future<void>.delayed(Duration.zero);
        },
        (error, stackTrace) {
          zoneErrors.add(error);
        },
      );

      expect(error, l10n.failedToDecodeImage);
      expect(zoneErrors, isEmpty);
    },
  );

  test('transient API image failures remain retryable across loads', () async {
    final workerManager = WorkerManager(maxConcurrentTasks: 1);
    final api = _TransientImageApi(workerManager);
    addTearDown(() {
      api.dispose();
      workerManager.dispose();
    });
    final scope = ImageAttachmentCacheScope(
      api: api,
      authSessionEpoch: Object(),
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    for (var attempt = 0; attempt < 2; attempt += 1) {
      final error = await debugLoadImageAttachmentError(
        attachmentId: 'server-file-id',
        workerManager: workerManager,
        l10n: l10n,
        api: api,
        scope: scope,
      );
      check(error).isNotNull();
      check(
        debugHasImageAttachmentError('server-file-id', scope: scope),
      ).isFalse();
    }
    check(api.fileInfoAttempts).equals(2);
  });
}

final class _EpochNotifier extends Notifier<Object> {
  _EpochNotifier(this.initial);

  final Object initial;

  @override
  Object build() => initial;

  void replace(Object value) => state = value;
}

final class _TransientImageApi extends ApiService {
  _TransientImageApi(WorkerManager workerManager)
    : super(
        serverConfig: const ServerConfig(
          id: 'transient-image-api',
          name: 'Transient image API',
          url: 'https://example.test',
        ),
        workerManager: workerManager,
      );

  int fileInfoAttempts = 0;

  @override
  Future<Map<String, dynamic>> getFileInfo(
    String fileId, {
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    fileInfoAttempts += 1;
    throw StateError('temporary image metadata outage');
  }
}
