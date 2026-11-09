import 'dart:async';
import 'dart:typed_data';

import 'package:conduit/core/services/image_attachment_cache_service.dart';
import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart'
    show debugLoadImageAttachmentError;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryStore implements LibreChatSessionStore {
  LibreChatSession? session;

  @override
  Future<LibreChatSession?> read() async => session;

  @override
  Future<void> write(LibreChatSession value) async => session = value;

  @override
  Future<void> clear() async => session = null;
}

/// The signed-in LibreChat session, swapped by the test.
final class _HandleSlot extends Notifier<LibreChatSessionHandle?> {
  _HandleSlot(this.initial);

  final LibreChatSessionHandle initial;

  @override
  LibreChatSessionHandle? build() => initial;

  void use(LibreChatSessionHandle? handle) => state = handle;
}

/// The Open WebUI session epoch, swapped by the test.
final class _EpochSlot extends Notifier<Object> {
  @override
  Object build() => Object();

  void next() => state = Object();
}

LibreChatSessionHandle _handle() => LibreChatSessionHandle(
  session: const LibreChatSession(
    accessToken: 'token',
    user: LibreChatUser(id: 'user1'),
  ),
  store: _MemoryStore(),
  renew: (current) async => current,
);

void main() {
  setUp(debugResetImageAttachmentCaches);
  tearDown(debugResetImageAttachmentCaches);

  test('server paths belong to LibreChat while it is signed in', () {
    final handle = _handle();
    addTearDown(handle.dispose);
    Future<Uint8List> fetch(String path) async => Uint8List(0);
    final epoch = Object();
    final container = ProviderContainer(
      overrides: [
        libreChatImageFetcherProvider.overrideWithValue(fetch),
        libreChatSessionHandleProvider.overrideWithValue(handle),
        apiServiceProvider.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
      ],
    );
    addTearDown(container.dispose);

    final scope = imageAttachmentCacheScopeFor(
      container.read,
      '/images/user1/f1.png',
    );
    expect(scope?.fetchPath, same(fetch));
    expect(scope?.authSessionEpoch, same(handle));
    expect(
      scope,
      ImageAttachmentCacheScope.libreChat(session: handle, fetchPath: fetch),
    );

    // An Open WebUI file id is not a LibreChat path.
    final owui = imageAttachmentCacheScopeFor(container.read, 'file-1');
    expect(owui?.fetchPath, isNull);
    expect(owui?.authSessionEpoch, same(epoch));
    expect(
      imageAttachmentCacheScopeFor(container.read, 'https://x.test/a.png'),
      isNull,
    );
  });

  test('without a LibreChat session, server paths stay Open WebUI\'s', () {
    final epoch = Object();
    final container = ProviderContainer(
      overrides: [
        libreChatImageFetcherProvider.overrideWithValue(null),
        apiServiceProvider.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
      ],
    );
    addTearDown(container.dispose);

    final scope = imageAttachmentCacheScopeFor(container.read, '/images/a.png');
    expect(scope?.fetchPath, isNull);
    expect(scope?.authSessionEpoch, same(epoch));
  });

  test('a LibreChat image is fetched once, then served as bytes', () async {
    final workerManager = WorkerManager(maxConcurrentTasks: 1);
    addTearDown(workerManager.dispose);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final handle = _handle();
    addTearDown(handle.dispose);
    final paths = <String>[];
    final scope = ImageAttachmentCacheScope.libreChat(
      session: handle,
      fetchPath: (path) async {
        paths.add(path);
        return Uint8List.fromList([137, 80, 78, 71]);
      },
    );

    for (var i = 0; i < 2; i++) {
      final error = await debugLoadImageAttachmentError(
        attachmentId: '/images/user1/f1.png',
        workerManager: workerManager,
        l10n: l10n,
        scope: scope,
      );
      expect(error, isNull);
    }
    expect(paths, ['/images/user1/f1.png']);
    expect(
      debugHasDecodedImageAttachment('/images/user1/f1.png', scope: scope),
      isTrue,
    );
  });

  test('a signed-out LibreChat session is let go, and its images stay '
      'fenced out', () async {
    final retired = _handle();
    final next = _handle();
    addTearDown(retired.dispose);
    addTearDown(next.dispose);
    final slot = NotifierProvider<_HandleSlot, LibreChatSessionHandle?>(
      () => _HandleSlot(retired),
    );
    final container = ProviderContainer(
      overrides: [
        libreChatSessionHandleProvider.overrideWith((ref) => ref.watch(slot)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(imageAttachmentCacheLifecycleProvider, (_, _) {});

    Future<Uint8List> fetch(String path) async => Uint8List(0);
    final retiredScope = ImageAttachmentCacheScope.libreChat(
      session: retired,
      fetchPath: fetch,
    );
    final openWebUiScope = ImageAttachmentCacheScope(
      api: null,
      authSessionEpoch: Object(),
    );
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    preCacheImageBytes('/images/user1/f1.png', bytes, scope: retiredScope);
    preCacheImageBytes('file-1', bytes, scope: openWebUiScope);
    expect(debugImageAttachmentCacheRetains(retired), isTrue);

    container.read(slot.notifier).use(next);
    await container.pump();

    // Nothing here keeps the old session's credentials alive.
    expect(debugImageAttachmentCacheRetains(retired), isFalse);
    // Another account's images stay.
    expect(
      debugHasDecodedImageAttachment('file-1', scope: openWebUiScope),
      isTrue,
    );
    // A load that still holds the old session cannot write it back.
    preCacheImageBytes('/images/user1/f1.png', bytes, scope: retiredScope);
    expect(
      debugHasDecodedImageAttachment(
        '/images/user1/f1.png',
        scope: retiredScope,
      ),
      isFalse,
    );
    expect(debugImageAttachmentCacheRetains(retired), isFalse);
  });

  test('an Open WebUI account change leaves the LibreChat session in use '
      'caching', () async {
    final handle = _handle();
    addTearDown(handle.dispose);
    final epoch = NotifierProvider<_EpochSlot, Object>(_EpochSlot.new);
    final container = ProviderContainer(
      overrides: [
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(epoch),
        ),
        libreChatSessionHandleProvider.overrideWith((ref) => handle),
      ],
    );
    addTearDown(container.dispose);
    container.listen(imageAttachmentCacheLifecycleProvider, (_, _) {});
    final scope = ImageAttachmentCacheScope.libreChat(
      session: handle,
      fetchPath: (path) async => Uint8List(0),
    );
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    preCacheImageBytes('/images/user1/f1.png', bytes, scope: scope);

    // Open WebUI switches accounts and back while LibreChat stays signed in.
    container.read(epoch.notifier).next();
    await container.pump();

    preCacheImageBytes('/images/user1/f1.png', bytes, scope: scope);
    expect(
      debugHasDecodedImageAttachment('/images/user1/f1.png', scope: scope),
      isTrue,
    );
  });

  test('an image still loading when its session is let go is not shown',
      () async {
    final workerManager = WorkerManager(maxConcurrentTasks: 1);
    addTearDown(workerManager.dispose);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final retired = _handle();
    final next = _handle();
    addTearDown(retired.dispose);
    addTearDown(next.dispose);
    final slot = NotifierProvider<_HandleSlot, LibreChatSessionHandle?>(
      () => _HandleSlot(retired),
    );
    final container = ProviderContainer(
      overrides: [
        libreChatSessionHandleProvider.overrideWith((ref) => ref.watch(slot)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(imageAttachmentCacheLifecycleProvider, (_, _) {});

    final reached = Completer<void>();
    final answer = Completer<Uint8List>();
    final scope = ImageAttachmentCacheScope.libreChat(
      session: retired,
      fetchPath: (path) {
        reached.complete();
        return answer.future;
      },
    );
    final load = debugLoadImageAttachmentError(
      attachmentId: '/images/user1/f1.png',
      workerManager: workerManager,
      l10n: l10n,
      scope: scope,
    );
    await reached.future;
    container.read(slot.notifier).use(next);
    await container.pump();
    answer.complete(Uint8List.fromList([137, 80, 78, 71]));

    expect(await load, isNotNull);
    expect(debugImageAttachmentCacheRetains(retired), isFalse);
  });

  test('a refused LibreChat image is retried on the next load', () async {
    final workerManager = WorkerManager(maxConcurrentTasks: 1);
    addTearDown(workerManager.dispose);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final handle = _handle();
    addTearDown(handle.dispose);
    var calls = 0;
    final scope = ImageAttachmentCacheScope.libreChat(
      session: handle,
      fetchPath: (path) async {
        calls++;
        if (calls == 1) throw StateError('refused');
        return Uint8List.fromList([137, 80, 78, 71]);
      },
    );

    final first = await debugLoadImageAttachmentError(
      attachmentId: '/images/user1/f1.png',
      workerManager: workerManager,
      l10n: l10n,
      scope: scope,
    );
    expect(first, startsWith(l10n.failedToLoadImage('').trim()));
    final second = await debugLoadImageAttachmentError(
      attachmentId: '/images/user1/f1.png',
      workerManager: workerManager,
      l10n: l10n,
      scope: scope,
    );
    expect(second, isNull);
    expect(calls, 2);
  });
}
