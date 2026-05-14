import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _flushMicrotasks([int count = 1]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('Conversations', () {
    test('passive refresh reuses an in-flight initial load', () async {
      final api = _SequencedConversationsApiService();
      final storage = _FakeOptimizedStorageService();
      final container = _container(api: api, storage: storage);
      addTearDown(container.dispose);

      final initialLoad = container.read(conversationsProvider.future);
      await _flushMicrotasks();

      final refreshFuture = container
          .read(conversationsProvider.notifier)
          .refresh();
      await _flushMicrotasks();

      check(api.requestedPages).deepEquals([1]);

      api.completePage(0, [_conversation('shared-load', folderId: 'folder-a')]);

      final initial = await initialLoad;
      await refreshFuture;
      final current = container.read(conversationsProvider).requireValue;

      check(
        initial.map((conversation) => conversation.id).toList(),
      ).deepEquals(['shared-load']);
      check(
        current.map((conversation) => conversation.id).toList(),
      ).deepEquals(['shared-load']);
    });

    test(
      'cache-hydrated folder conversations are not preserved into the first remote refresh',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService(
          localConversations: [
            _conversation('cached-folder-chat', folderId: 'folder-old'),
          ],
        );
        final container = _container(api: api, storage: storage);
        addTearDown(container.dispose);

        final initial = await container.read(conversationsProvider.future);
        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['cached-folder-chat']);

        await _flushMicrotasks();
        check(api.requestedPages).deepEquals([1]);

        api.completePage(0, [_conversation('fresh-root-chat')]);
        await _flushMicrotasks(2);

        final current = container.read(conversationsProvider).requireValue;
        check(
          current.map((conversation) => conversation.id).toList(),
        ).deepEquals(['fresh-root-chat']);
      },
    );

    test(
      'local mutations do not re-trust cache-hydrated folder conversations before the first refresh',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService(
          localConversations: [
            _conversation('cached-folder-chat', folderId: 'folder-old'),
          ],
        );
        final container = _container(api: api, storage: storage);
        addTearDown(container.dispose);

        final initial = await container.read(conversationsProvider.future);
        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['cached-folder-chat']);

        await _flushMicrotasks();
        check(api.requestedPages).deepEquals([1]);

        container
            .read(conversationsProvider.notifier)
            .updateConversation(
              'cached-folder-chat',
              (conversation) => conversation.copyWith(title: 'Updated locally'),
            );

        api.completePage(0, [_conversation('fresh-root-chat')]);
        await _flushMicrotasks(2);

        final current = container.read(conversationsProvider).requireValue;
        check(
          current.map((conversation) => conversation.id).toList(),
        ).deepEquals(['fresh-root-chat']);
      },
    );

    test(
      'server-confirmed mutations re-trust cache-hydrated folder conversations before the first refresh',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService(
          localConversations: [
            _conversation('cached-folder-chat', folderId: 'folder-old'),
          ],
        );
        final container = _container(api: api, storage: storage);
        addTearDown(container.dispose);

        final initial = await container.read(conversationsProvider.future);
        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['cached-folder-chat']);

        await _flushMicrotasks();
        check(api.requestedPages).deepEquals([1]);

        container
            .read(conversationsProvider.notifier)
            .updateConversationFromRemote(
              'cached-folder-chat',
              (conversation) => conversation.copyWith(
                title: 'Updated remotely',
                updatedAt: DateTime.utc(2026, 1, 2),
              ),
            );

        api.completePage(0, [_conversation('fresh-root-chat')]);
        await _flushMicrotasks(2);

        final current = container.read(conversationsProvider).requireValue;
        check(
          current.map((conversation) => conversation.id).toList(),
        ).deepEquals(['cached-folder-chat', 'fresh-root-chat']);
      },
    );

    test(
      'forced refresh does not re-trust cached folder conversations while a warm refresh is in flight',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService(
          localConversations: [
            _conversation('cached-folder-chat', folderId: 'folder-old'),
          ],
        );
        final container = _container(api: api, storage: storage);
        addTearDown(container.dispose);

        final initial = await container.read(conversationsProvider.future);
        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['cached-folder-chat']);

        await _flushMicrotasks();
        check(api.requestedPages).deepEquals([1]);

        final refreshFuture = container
            .read(conversationsProvider.notifier)
            .refresh(forceFresh: true);
        await _flushMicrotasks();

        check(api.requestedPages).deepEquals([1, 1]);

        api.completePage(0, [_conversation('older-refresh-root-chat')]);
        await _flushMicrotasks(2);

        api.completePage(1, [_conversation('fresh-root-chat')]);

        await refreshFuture;
        final current = container.read(conversationsProvider).requireValue;

        check(current).has((it) => it.length, 'length').equals(1);
        check(current.single.id).equals('fresh-root-chat');
      },
    );

    test(
      'folder summaries reload on auth token changes and ignore stale responses',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);
        final subscription = container.listen<AsyncValue<List<Conversation>>>(
          folderConversationSummariesProvider('folder-old'),
          (previous, next) {},
        );
        addTearDown(subscription.close);

        container.read(folderConversationSummariesProvider('folder-old'));
        await _flushMicrotasks();

        check(api.requestedFolderIds).deepEquals(['folder-old']);
        check(api.requestedFolderAuthTokens).deepEquals(['old-token']);

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        container
            .read(conversationsProvider.notifier)
            .upsertConversation(_conversation('new-root-chat'));
        await _flushMicrotasks();

        check(api.requestedFolderIds).deepEquals(['folder-old', 'folder-old']);
        check(
          api.requestedFolderAuthTokens,
        ).deepEquals(['old-token', 'new-token']);

        api.completeFolderConversationSummaries(0, [
          _conversation('stale-folder-chat', folderId: 'folder-old'),
        ]);
        await _flushMicrotasks(2);

        api.completeFolderConversationSummaries(1, [
          _conversation('fresh-folder-chat', folderId: 'folder-old'),
        ]);

        final returned = await container.read(
          folderConversationSummariesProvider('folder-old').future,
        );
        await _flushMicrotasks(2);

        check(
          returned.map((conversation) => conversation.id).toList(),
        ).deepEquals(['fresh-folder-chat']);
        final current = container.read(conversationsProvider).requireValue;
        check(
          current.map((conversation) => conversation.id).toSet(),
        ).deepEquals({'fresh-folder-chat', 'new-root-chat'});
      },
    );

    test(
      'cache-backed conversations warm folders via warmIfNeeded instead of forcing folder refresh',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService(
          localConversations: [_conversation('cached-chat')],
        );
        final container = ProviderContainer(
          overrides: [
            isAuthenticatedProvider2.overrideWithValue(true),
            reviewerModeProvider.overrideWithValue(false),
            authTokenProvider3.overrideWithValue('test-token'),
            apiServiceProvider.overrideWithValue(api),
            optimizedStorageServiceProvider.overrideWithValue(storage),
            foldersProvider.overrideWith(_RecordingWarmIfNeededFolders.new),
          ],
        );
        addTearDown(container.dispose);

        final initial = await container.read(conversationsProvider.future);
        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['cached-chat']);

        await _flushMicrotasks();

        final folders =
            container.read(foldersProvider.notifier)
                as _RecordingWarmIfNeededFolders;
        check(folders.warmIfNeededCalls).equals(1);
        check(folders.refreshCalls).equals(0);

        api.completePage(0, [_conversation('fresh-chat')]);
        await _flushMicrotasks(2);

        final current = container.read(conversationsProvider).requireValue;
        check(
          current.map((conversation) => conversation.id).toList(),
        ).deepEquals(['fresh-chat']);
        check(folders.warmIfNeededCalls).equals(1);
        check(folders.refreshCalls).equals(0);
      },
    );

    test(
      'refreshConversationsCache forces folders to refresh immediately in parallel',
      () async {
        final container = ProviderContainer(
          overrides: [
            conversationsProvider.overrideWith(
              _BlockingRefreshConversations.new,
            ),
            foldersProvider.overrideWith(_RecordingRefreshFolders.new),
          ],
        );
        addTearDown(container.dispose);

        final conversations =
            container.read(conversationsProvider.notifier)
                as _BlockingRefreshConversations;
        final folders =
            container.read(foldersProvider.notifier)
                as _RecordingRefreshFolders;

        refreshConversationsCache(container, includeFolders: true);
        await _flushMicrotasks();

        check(conversations.refreshCalls).equals(1);
        check(conversations.lastIncludeFolders).equals(false);
        check(conversations.lastForceFresh).equals(true);
        check(folders.refreshCalls).equals(1);
        check(folders.lastForceFresh).equals(true);
        check(conversations.refreshCompleter.isCompleted).equals(false);

        conversations.refreshCompleter.complete();
        await _flushMicrotasks();
      },
    );

    test('forced refresh supersedes an older initial load', () async {
      final api = _SequencedConversationsApiService();
      final storage = _FakeOptimizedStorageService();
      final container = _container(api: api, storage: storage);
      addTearDown(container.dispose);

      final initialLoad = container.read(conversationsProvider.future);
      await _flushMicrotasks();

      final refreshFuture = container
          .read(conversationsProvider.notifier)
          .refresh(forceFresh: true);
      await _flushMicrotasks();

      check(api.requestedPages).deepEquals([1, 1]);

      api.completePage(0, [
        _conversation('stale-load', folderId: 'folder-stale'),
      ]);
      await _flushMicrotasks();

      api.completePage(1, [
        _conversation('fresh-load', folderId: 'folder-fresh'),
      ]);

      final initial = await initialLoad;
      await refreshFuture;
      final current = container.read(conversationsProvider).requireValue;

      check(
        initial.map((conversation) => conversation.id).toList(),
      ).deepEquals(['fresh-load']);
      check(
        current.map((conversation) => conversation.id).toList(),
      ).deepEquals(['fresh-load']);
      check(current.first.folderId).equals('folder-fresh');
    });

    test('forced refresh keeps fresh load when it completes first', () async {
      final api = _SequencedConversationsApiService();
      final storage = _FakeOptimizedStorageService();
      final container = _container(api: api, storage: storage);
      addTearDown(container.dispose);

      final initialLoad = container.read(conversationsProvider.future);
      await _flushMicrotasks();

      final refreshFuture = container
          .read(conversationsProvider.notifier)
          .refresh(forceFresh: true);
      await _flushMicrotasks();

      check(api.requestedPages).deepEquals([1, 1]);

      api.completePage(1, [
        _conversation('fresh-load', folderId: 'folder-fresh'),
      ]);
      await _flushMicrotasks();

      api.completePage(0, [
        _conversation('stale-load', folderId: 'folder-stale'),
      ]);

      final initial = await initialLoad;
      await refreshFuture;
      final current = container.read(conversationsProvider).requireValue;

      check(
        initial.map((conversation) => conversation.id).toList(),
      ).deepEquals(['fresh-load']);
      check(
        current.map((conversation) => conversation.id).toList(),
      ).deepEquals(['fresh-load']);
      check(current.first.folderId).equals('folder-fresh');
    });

    test(
      'passive refresh starts a new load after auth token changes',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(conversationsProvider.future);
        await _flushMicrotasks();

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        final refreshFuture = container
            .read(conversationsProvider.notifier)
            .refresh();
        await _flushMicrotasks();

        check(api.requestedPages).deepEquals([1, 1]);
        check(
          api.requestedPageAuthTokens,
        ).deepEquals(['old-token', 'new-token']);

        api.completePage(0, [
          _conversation('old-token-load', folderId: 'folder-old'),
        ]);
        await _flushMicrotasks();

        api.completePage(1, [
          _conversation('new-token-load', folderId: 'folder-new'),
        ]);

        final initial = await initialLoad;
        await refreshFuture;
        final current = container.read(conversationsProvider).requireValue;

        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['new-token-load']);
        check(
          current.map((conversation) => conversation.id).toList(),
        ).deepEquals(['new-token-load']);
        check(current.first.folderId).equals('folder-new');
      },
    );

    test(
      'refresh drops folder conversations from the previous auth scope after a settled load',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(conversationsProvider.future);
        await _flushMicrotasks();

        api.completePage(0, [
          _conversation('old-folder-chat', folderId: 'folder-old'),
        ]);

        final initial = await initialLoad;
        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['old-folder-chat']);

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        final refreshFuture = container
            .read(conversationsProvider.notifier)
            .refresh();
        await _flushMicrotasks();

        check(api.requestedPages).deepEquals([1, 1]);

        api.completePage(1, [_conversation('new-root-chat')]);

        await refreshFuture;
        final current = container.read(conversationsProvider).requireValue;

        check(
          current.map((conversation) => conversation.id).toList(),
        ).deepEquals(['new-root-chat']);
      },
    );

    test(
      'refresh clears a trusted folder assignment when the server returns the chat at root',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService();
        final container = _container(api: api, storage: storage);
        addTearDown(container.dispose);

        final initialLoad = container.read(conversationsProvider.future);
        await _flushMicrotasks();

        api.completePage(0, [
          _conversation('moved-chat', folderId: 'folder-old'),
        ]);

        final initial = await initialLoad;
        check(initial).has((it) => it.length, 'length').equals(1);
        check(initial.single.folderId).equals('folder-old');

        final refreshFuture = container
            .read(conversationsProvider.notifier)
            .refresh(forceFresh: true);
        await _flushMicrotasks();

        check(api.requestedPages).deepEquals([1, 1]);

        api.completePage(1, [_conversation('moved-chat')]);

        await refreshFuture;
        final current = container.read(conversationsProvider).requireValue;

        check(current).has((it) => it.length, 'length').equals(1);
        check(current.single.id).equals('moved-chat');
        check(current.single.folderId).isNull();
      },
    );

    test(
      'stale-scope local mutations do not overwrite the persisted cache',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(conversationsProvider.future);
        await _flushMicrotasks();

        api.completePage(0, [_conversation('old-chat')]);

        final initial = await initialLoad;
        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['old-chat']);
        await _flushMicrotasks();
        check(storage.savedConversationSnapshots).deepEquals([
          ['old-chat'],
        ]);

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        container
            .read(conversationsProvider.notifier)
            .upsertConversation(_conversation('new-root-chat'));
        await _flushMicrotasks();

        final current = container.read(conversationsProvider).requireValue;
        check(
          current.map((conversation) => conversation.id).toSet(),
        ).deepEquals({'old-chat', 'new-root-chat'});
        check(storage.savedConversationSnapshots).deepEquals([
          ['old-chat'],
        ]);
      },
    );

    test(
      'loadMore refreshes the current scope instead of appending stale pages after auth token changes',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(conversationsProvider.future);
        await _flushMicrotasks();

        api.completePage(
          0,
          List<Conversation>.generate(
            50,
            (index) => _conversation('old-page-$index'),
          ),
        );

        final initial = await initialLoad;
        check(initial).has((it) => it.length, 'length').equals(50);

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        final loadMoreFuture = container
            .read(conversationsProvider.notifier)
            .loadMore();
        await _flushMicrotasks();

        check(api.requestedPages).deepEquals([1, 1]);

        api.completePage(1, [_conversation('new-page-1')]);

        await loadMoreFuture;
        final current = container.read(conversationsProvider).requireValue;
        check(
          current.map((conversation) => conversation.id).toList(),
        ).deepEquals(['new-page-1']);
      },
    );

    test(
      'refresh clears trusted conversations when a new-scope load fails',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(conversationsProvider.future);
        await _flushMicrotasks();

        api.completePage(0, [_conversation('old-chat')]);

        final initial = await initialLoad;
        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['old-chat']);
        await _flushMicrotasks();
        check(storage.savedConversationSnapshots).deepEquals([
          ['old-chat'],
        ]);

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        final refreshFuture = container
            .read(conversationsProvider.notifier)
            .refresh();
        await _flushMicrotasks();

        check(api.requestedPages).deepEquals([1, 1]);
        check(
          api.requestedPageAuthTokens,
        ).deepEquals(['old-token', 'new-token']);

        api.failPage(Exception('new-scope refresh failed'), index: 1);

        await refreshFuture;
        await _flushMicrotasks();
        final current = container.read(conversationsProvider).requireValue;

        check(current).isEmpty();
        check(storage.savedConversationSnapshots).deepEquals([
          ['old-chat'],
        ]);
      },
    );

    test(
      'a stale refresh failure does not clear newer conversations from a new auth scope',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(conversationsProvider.future);
        await _flushMicrotasks();

        api.completePage(0, [_conversation('old-chat')]);

        final initial = await initialLoad;
        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['old-chat']);
        await _flushMicrotasks();

        final notifier = container.read(conversationsProvider.notifier);
        final staleRefresh = notifier.refresh(forceFresh: true);
        await _flushMicrotasks();

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        final freshRefresh = notifier.refresh(forceFresh: true);
        await _flushMicrotasks();

        check(api.requestedPages).deepEquals([1, 1, 1]);
        check(
          api.requestedPageAuthTokens,
        ).deepEquals(['old-token', 'old-token', 'new-token']);

        api.completePage(2, [_conversation('new-chat')]);

        await freshRefresh;
        await _flushMicrotasks();
        check(
          container
              .read(conversationsProvider)
              .requireValue
              .map((conversation) => conversation.id)
              .toList(),
        ).deepEquals(['new-chat']);

        api.failPage(Exception('stale refresh failed'), index: 1);

        await staleRefresh;
        await _flushMicrotasks();
        final current = container.read(conversationsProvider).requireValue;

        check(
          current.map((conversation) => conversation.id).toList(),
        ).deepEquals(['new-chat']);
      },
    );

    test(
      'forced refresh preserves the current conversations when the page-1 fetch fails',
      () async {
        final api = _SequencedConversationsApiService();
        final storage = _FakeOptimizedStorageService();
        final container = _container(api: api, storage: storage);
        addTearDown(container.dispose);

        final initialLoad = container.read(conversationsProvider.future);
        await _flushMicrotasks();

        api.completePage(0, [_conversation('existing-chat')]);

        final initial = await initialLoad;
        check(
          initial.map((conversation) => conversation.id).toList(),
        ).deepEquals(['existing-chat']);
        await _flushMicrotasks();
        check(storage.savedConversationSnapshots).deepEquals([
          ['existing-chat'],
        ]);

        final refreshFuture = container
            .read(conversationsProvider.notifier)
            .refresh(forceFresh: true);
        await _flushMicrotasks();

        check(api.requestedPages).deepEquals([1, 1]);

        api.failPage(Exception('refresh failed'), index: 1);

        await refreshFuture;
        await _flushMicrotasks();
        final current = container.read(conversationsProvider).requireValue;

        check(
          current.map((conversation) => conversation.id).toList(),
        ).deepEquals(['existing-chat']);
        check(storage.savedConversationSnapshots).deepEquals([
          ['existing-chat'],
        ]);
      },
    );

    test('initial load failures surface as provider errors', () async {
      final api = _SequencedConversationsApiService();
      final storage = _FakeOptimizedStorageService();
      final container = _container(api: api, storage: storage);
      addTearDown(container.dispose);
      final subscription = container.listen<AsyncValue<List<Conversation>>>(
        conversationsProvider,
        (previous, next) {},
      );
      addTearDown(subscription.close);

      container.read(conversationsProvider);
      await _flushMicrotasks();

      api.failPage(Exception('initial load failed'));

      await _flushMicrotasks(2);

      final current = container.read(conversationsProvider);
      check(current.hasError).isTrue();
      expect(() => current.requireValue, throwsA(anything));
      check(storage.savedConversationSnapshots).isEmpty();
    });
  });
}

ProviderContainer _container({
  required OptimizedStorageService storage,
  ApiService? api,
  Override? apiOverride,
  Override? authTokenOverride,
}) {
  assert(api != null || apiOverride != null);
  return ProviderContainer(
    overrides: [
      isAuthenticatedProvider2.overrideWithValue(true),
      reviewerModeProvider.overrideWithValue(false),
      authTokenOverride ?? authTokenProvider3.overrideWithValue('test-token'),
      apiOverride ?? apiServiceProvider.overrideWithValue(api!),
      optimizedStorageServiceProvider.overrideWithValue(storage),
    ],
  );
}

Conversation _conversation(String id, {String? folderId}) {
  final timestamp = DateTime.utc(2026, 1, 1);
  return Conversation(
    id: id,
    title: id,
    createdAt: timestamp,
    updatedAt: timestamp,
    folderId: folderId,
  );
}

class _FakeOptimizedStorageService extends Fake
    implements OptimizedStorageService {
  _FakeOptimizedStorageService({
    List<Conversation> localConversations = const <Conversation>[],
  }) : _localConversations = List<Conversation>.unmodifiable(
         localConversations,
       );

  final List<Conversation> _localConversations;
  final savedConversationSnapshots = <List<String>>[];

  @override
  Future<List<Conversation>> getLocalConversations() async =>
      _localConversations;

  @override
  Future<void> saveLocalConversations(List<Conversation> conversations) async {
    savedConversationSnapshots.add(
      conversations.map((conversation) => conversation.id).toList(),
    );
  }

  @override
  Future<List<Folder>> getLocalFolders() async => const <Folder>[];

  @override
  Future<void> saveLocalFolders(List<Folder> folders) async {}
}

class _BlockingRefreshConversations extends Conversations {
  int refreshCalls = 0;
  bool? lastIncludeFolders;
  bool? lastForceFresh;
  final refreshCompleter = Completer<void>();

  @override
  Future<List<Conversation>> build() async => const <Conversation>[];

  @override
  Future<void> refresh({
    bool includeFolders = false,
    bool forceFresh = false,
  }) async {
    refreshCalls += 1;
    lastIncludeFolders = includeFolders;
    lastForceFresh = forceFresh;
    await refreshCompleter.future;
  }
}

class _RecordingRefreshFolders extends Folders {
  int refreshCalls = 0;
  bool? lastForceFresh;

  @override
  Future<List<Folder>> build() async => const <Folder>[];

  @override
  Future<void> refresh({bool forceFresh = false}) async {
    refreshCalls += 1;
    lastForceFresh = forceFresh;
  }
}

class _RecordingWarmIfNeededFolders extends Folders {
  int refreshCalls = 0;
  int warmIfNeededCalls = 0;

  @override
  Future<List<Folder>> build() async => const <Folder>[];

  @override
  Future<void> refresh({bool forceFresh = false}) async {
    refreshCalls += 1;
  }

  @override
  Future<void> warmIfNeeded() async {
    warmIfNeededCalls += 1;
    state = const AsyncData<List<Folder>>(<Folder>[]);
  }
}

class _SequencedConversationsApiService extends ApiService {
  _SequencedConversationsApiService()
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final requestedPages = <int>[];
  final requestedPageAuthTokens = <String?>[];
  final _pageCompleters = <Completer<List<Conversation>>>[];
  final requestedFolderIds = <String>[];
  final requestedFolderAuthTokens = <String?>[];
  final _folderConversationCompleters = <Completer<List<Conversation>>>[];

  @override
  Future<List<Conversation>> getConversationPage({
    int page = 1,
    bool includeFolders = true,
    bool includePinned = false,
  }) {
    requestedPages.add(page);
    requestedPageAuthTokens.add(authToken);
    final completer = Completer<List<Conversation>>();
    _pageCompleters.add(completer);
    return completer.future;
  }

  void completePage(int index, List<Conversation> conversations) {
    _pageCompleters[index].complete(conversations);
  }

  void failPage(Object error, {int index = 0}) {
    _pageCompleters[index].completeError(error);
  }

  @override
  Future<List<Conversation>> getFolderConversationSummaries(String folderId) {
    requestedFolderIds.add(folderId);
    requestedFolderAuthTokens.add(authToken);
    final completer = Completer<List<Conversation>>();
    _folderConversationCompleters.add(completer);
    return completer.future;
  }

  void completeFolderConversationSummaries(
    int index,
    List<Conversation> conversations,
  ) {
    _folderConversationCompleters[index].complete(conversations);
  }

  @override
  Future<List<Conversation>> getPinnedChats() async => const <Conversation>[];

  @override
  Future<List<Conversation>> getArchivedChats({
    int? limit,
    int? offset,
  }) async => const <Conversation>[];

  @override
  Future<(List<Map<String, dynamic>>, bool)> getFolders() async =>
      (const <Map<String, dynamic>>[], true);
}
