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
