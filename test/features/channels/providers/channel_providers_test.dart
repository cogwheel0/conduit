import 'dart:async';

import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/channel_message.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/channels/providers/channel_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChannelsList', () {
    test(
      'ignores stale feature results after the active token changes',
      () async {
        final staleGate = Completer<void>();
        final currentGate = Completer<void>();
        final staleApi = _FakeChannelApiService(
          featureEnabled: false,
          gate: staleGate.future,
        );
        final currentApi = _FakeChannelApiService(
          rawChannels: [
            {'id': 'current-channel', 'name': 'Current', 'updated_at': 2},
          ],
          gate: currentGate.future,
        );
        final activeApiProvider =
            NotifierProvider<_MutableValue<ApiService?>, ApiService?>(
              () => _MutableValue<ApiService?>(staleApi),
            );
        final tokenProvider = NotifierProvider<_MutableValue<String?>, String?>(
          () => _MutableValue<String?>('token-1'),
        );
        final container = ProviderContainer(
          overrides: [
            apiServiceProvider.overrideWith(
              (ref) => ref.watch(activeApiProvider),
            ),
            authTokenProvider3.overrideWith((ref) => ref.watch(tokenProvider)),
          ],
        );
        addTearDown(container.dispose);

        final subscription = container.listen(
          channelsListProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        await _waitFor(() => staleApi.requests == 1);

        container.read(activeApiProvider.notifier).set(currentApi);
        container.read(tokenProvider.notifier).set('token-2');
        await _waitFor(() => currentApi.requests == 1);

        staleGate.complete();
        await Future<void>.delayed(Duration.zero);

        expect(container.read(channelsFeatureEnabledProvider), isTrue);

        currentGate.complete();

        final channels = await container.read(channelsListProvider.future);

        expect(channels.single.id, 'current-channel');
        expect(container.read(channelsFeatureEnabledProvider), isTrue);
      },
    );

    test('a slower refresh cannot overwrite a newer refresh', () async {
      final api = _QueuedChannelsApi();
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          authTokenProvider3.overrideWith((ref) => 'token'),
        ],
      );
      addTearDown(container.dispose);
      await container.read(channelsListProvider.future);

      final stale = container.read(channelsListProvider.notifier).refresh();
      final current = container.read(channelsListProvider.notifier).refresh();
      api.complete(2, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'current', 'name': 'Current'},
      ]);
      await current;
      api.complete(1, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'stale', 'name': 'Stale'},
      ]);
      await stale;

      expect(
        container.read(channelsListProvider).requireValue.single.id,
        'current',
      );
    });

    test(
      'a refresh cannot overwrite a channel mutation received while awaiting',
      () async {
        final api = _QueuedChannelsApi();
        final container = ProviderContainer(
          overrides: [
            apiServiceProvider.overrideWithValue(api),
            authTokenProvider3.overrideWith((ref) => 'token'),
          ],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(channelsListProvider, (_, _) {});
        addTearDown(subscription.close);
        await container.read(channelsListProvider.future);

        final refresh = container.read(channelsListProvider.notifier).refresh();
        final initial = container
            .read(channelsListProvider)
            .requireValue
            .single;
        container
            .read(channelsListProvider.notifier)
            .updateChannel(initial.copyWith(unreadCount: 1));
        api.complete(1, <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'initial',
            'name': 'Initial',
            'unread_count': 0,
          },
        ]);
        await refresh;

        expect(
          container.read(channelsListProvider).requireValue.single.unreadCount,
          1,
        );

        // The stale response is discarded, then one replacement refresh runs
        // so unrelated authoritative changes are not lost with it.
        await _waitFor(() => api.requestCount == 3);
        api.complete(2, <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'initial',
            'name': 'Initial',
            'unread_count': 1,
          },
          <String, dynamic>{'id': 'joined', 'name': 'Joined'},
        ]);
        final refreshed = await container.read(channelsListProvider.future);
        expect(refreshed.map((channel) => channel.id), contains('joined'));
      },
    );
  });

  group('ChannelsList.markRead (reset-on-visit)', () {
    Future<ProviderContainer> loadWith(
      List<Map<String, dynamic>> rawChannels,
    ) async {
      final api = _FakeChannelApiService(rawChannels: rawChannels);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          authTokenProvider3.overrideWith((ref) => 'token'),
        ],
      );
      addTearDown(container.dispose);
      await container.read(channelsListProvider.future);
      return container;
    }

    test('clears the unread badge for the opened channel', () async {
      final container = await loadWith([
        {'id': 'c1', 'name': 'One', 'unread_count': 3, 'updated_at': 2},
        {'id': 'c2', 'name': 'Two', 'unread_count': 5, 'updated_at': 1},
      ]);

      container.read(channelsListProvider.notifier).markRead('c1');

      final channels = container.read(channelsListProvider).value!;
      expect(channels.firstWhere((c) => c.id == 'c1').unreadCount, 0);
      // Other channels are untouched.
      expect(channels.firstWhere((c) => c.id == 'c2').unreadCount, 5);
    });

    test('is a no-op for an unknown or already-read channel', () async {
      final container = await loadWith([
        {'id': 'c1', 'name': 'One', 'unread_count': 0, 'updated_at': 1},
      ]);
      final before = container.read(channelsListProvider).value;

      container.read(channelsListProvider.notifier).markRead('c1');
      container.read(channelsListProvider.notifier).markRead('missing');

      // No rebuild: same list instance is retained when nothing changed.
      expect(
        identical(container.read(channelsListProvider).value, before),
        isTrue,
      );
    });
  });

  group('ChannelMessages pagination ownership', () {
    test('first-page fetch reruns after a live message arrives', () async {
      final api = _QueuedChannelContentApi();
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final provider = channelMessagesProvider('channel');
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final firstPage = container.read(provider.future);
      await _waitFor(() => api.messageRequestCount == 1);

      container
          .read(provider.notifier)
          .prependMessage(
            const ChannelMessage(id: 'socket-message', content: 'live'),
          );
      api.completeMessages(0, const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'stale-history', 'content': 'stale'},
      ]);
      await firstPage;
      expect(container.read(provider).requireValue.single.id, 'socket-message');

      await _waitFor(() => api.messageRequestCount == 2);
      api.completeMessages(1, const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'socket-message', 'content': 'live'},
        <String, dynamic>{'id': 'history', 'content': 'history'},
      ]);
      final messages = await container.read(provider.future);
      expect(messages.map((message) => message.id), [
        'socket-message',
        'history',
      ]);
    });

    test('first-page refresh preserves live updates and deletions', () async {
      final api = _QueuedChannelContentApi();
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final provider = channelMessagesProvider('channel');
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final initial = container.read(provider.future);
      await _waitFor(() => api.messageRequestCount == 1);
      api.completeMessages(0, const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'edit-me', 'content': 'old'},
        <String, dynamic>{'id': 'delete-me', 'content': 'old'},
      ]);
      await initial;

      container.invalidate(provider);
      final staleRefresh = container.read(provider.future);
      await _waitFor(() => api.messageRequestCount == 2);
      container
          .read(provider.notifier)
          .updateMessage(
            const ChannelMessage(id: 'edit-me', content: 'live edit'),
          );
      container.read(provider.notifier).removeMessage('delete-me');
      api.completeMessages(1, const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'edit-me', 'content': 'stale edit'},
        <String, dynamic>{'id': 'delete-me', 'content': 'stale delete'},
      ]);
      await staleRefresh;
      final retained = container.read(provider).requireValue;
      expect(retained.single.content, 'live edit');

      await _waitFor(() => api.messageRequestCount == 3);
      api.completeMessages(2, const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'edit-me', 'content': 'live edit'},
      ]);
      final refreshed = await container.read(provider.future);
      expect(refreshed.single.content, 'live edit');
    });

    test('thread first-page fetch reruns after a live reply arrives', () async {
      final api = _QueuedChannelContentApi();
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final provider = threadMessagesProvider('channel', 'parent');
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final firstPage = container.read(provider.future);
      await _waitFor(() => api.threadRequestCount == 1);

      container
          .read(provider.notifier)
          .prependMessage(
            const ChannelMessage(id: 'live-reply', content: 'live'),
          );
      api.completeThread(0, const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'stale-reply', 'content': 'stale'},
      ]);
      await firstPage;
      expect(container.read(provider).requireValue.single.id, 'live-reply');

      await _waitFor(() => api.threadRequestCount == 2);
      api.completeThread(1, const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'live-reply', 'content': 'live'},
        <String, dynamic>{'id': 'older-reply', 'content': 'older'},
      ]);
      final replies = await container.read(provider.future);
      expect(replies.map((message) => message.id), [
        'live-reply',
        'older-reply',
      ]);
    });

    test(
      'loadMore preserves socket messages received while awaiting',
      () async {
        final api = _PaginatedChannelApi(serverId: 'server-a');
        final container = ProviderContainer(
          overrides: [apiServiceProvider.overrideWithValue(api)],
        );
        addTearDown(container.dispose);
        final provider = channelMessagesProvider('channel');
        await container.read(provider.future);

        final load = container.read(provider.notifier).loadMore();
        await api.loadMoreStarted.future;
        container
            .read(provider.notifier)
            .prependMessage(
              const ChannelMessage(id: 'socket-message', content: 'live'),
            );
        api.releaseLoadMore.complete();
        await load;

        final messages = container.read(provider).requireValue;
        expect(messages.first.id, 'socket-message');
        expect(
          messages.any((message) => message.id == 'older-message'),
          isTrue,
        );
        expect(messages.length, 52);
      },
    );

    test('loadMore cannot publish after the API owner changes', () async {
      final firstApi = _PaginatedChannelApi(serverId: 'server-a');
      final secondApi = _PaginatedChannelApi(
        serverId: 'server-b',
        initialCount: 1,
      );
      final apiOwner =
          NotifierProvider<_MutableValue<ApiService?>, ApiService?>(
            () => _MutableValue<ApiService?>(firstApi),
          );
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWith((ref) => ref.watch(apiOwner)),
        ],
      );
      addTearDown(container.dispose);
      final provider = channelMessagesProvider('channel');
      await container.read(provider.future);

      final staleLoad = container.read(provider.notifier).loadMore();
      await firstApi.loadMoreStarted.future;
      container.read(apiOwner.notifier).set(secondApi);
      final current = await container.read(provider.future);
      expect(current.single.id, 'server-b-message-0');

      firstApi.releaseLoadMore.complete();
      await staleLoad;

      final messages = container.read(provider).requireValue;
      expect(messages.map((message) => message.id), ['server-b-message-0']);
    });
  });
}

class _FakeChannelApiService extends ApiService {
  _FakeChannelApiService({
    this.rawChannels = const <Map<String, dynamic>>[],
    this.featureEnabled = true,
    this.gate,
  }) : super(
         serverConfig: const ServerConfig(
           id: 'test',
           name: 'Test',
           url: 'https://example.com',
         ),
         workerManager: WorkerManager(),
       );

  final List<Map<String, dynamic>> rawChannels;
  final bool featureEnabled;
  final Future<void>? gate;
  var requests = 0;

  @override
  Future<(List<Map<String, dynamic>>, bool)> getChannels() async {
    requests++;
    final pendingGate = gate;
    if (pendingGate != null) {
      await pendingGate;
    }
    return (rawChannels, featureEnabled);
  }
}

class _PaginatedChannelApi extends ApiService {
  _PaginatedChannelApi({required String serverId, this.initialCount = 50})
    : _serverId = serverId,
      super(
        serverConfig: ServerConfig(
          id: serverId,
          name: serverId,
          url: 'https://$serverId.example.com',
        ),
        workerManager: WorkerManager(),
      );

  final String _serverId;
  final int initialCount;
  final Completer<void> loadMoreStarted = Completer<void>();
  final Completer<void> releaseLoadMore = Completer<void>();

  @override
  Future<List<Map<String, dynamic>>> getChannelMessages(
    String channelId, {
    int skip = 0,
    int limit = 50,
  }) async {
    if (skip == 0) {
      return List<Map<String, dynamic>>.generate(
        initialCount,
        (index) => <String, dynamic>{
          'id': '$_serverId-message-$index',
          'content': '$index',
        },
      );
    }
    if (!loadMoreStarted.isCompleted) loadMoreStarted.complete();
    await releaseLoadMore.future;
    return const <Map<String, dynamic>>[
      <String, dynamic>{'id': 'older-message', 'content': 'older'},
    ];
  }
}

class _QueuedChannelsApi extends ApiService {
  _QueuedChannelsApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'queued',
          name: 'Queued',
          url: 'https://queued.example.com',
        ),
        workerManager: WorkerManager(),
      );

  final List<Completer<(List<Map<String, dynamic>>, bool)>> _requests = [];

  int get requestCount => _requests.length;

  @override
  Future<(List<Map<String, dynamic>>, bool)> getChannels() {
    final request = Completer<(List<Map<String, dynamic>>, bool)>();
    _requests.add(request);
    if (_requests.length == 1) {
      request.complete((
        <Map<String, dynamic>>[
          <String, dynamic>{'id': 'initial', 'name': 'Initial'},
        ],
        true,
      ));
    }
    return request.future;
  }

  void complete(int requestIndex, List<Map<String, dynamic>> channels) {
    _requests[requestIndex].complete((channels, true));
  }
}

class _QueuedChannelContentApi extends ApiService {
  _QueuedChannelContentApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'queued-content',
          name: 'Queued content',
          url: 'https://queued-content.example.com',
        ),
        workerManager: WorkerManager(),
      );

  final List<Completer<List<Map<String, dynamic>>>> _messageRequests = [];
  final List<Completer<List<Map<String, dynamic>>>> _threadRequests = [];

  int get messageRequestCount => _messageRequests.length;
  int get threadRequestCount => _threadRequests.length;

  @override
  Future<List<Map<String, dynamic>>> getChannelMessages(
    String channelId, {
    int skip = 0,
    int limit = 50,
  }) {
    final request = Completer<List<Map<String, dynamic>>>();
    _messageRequests.add(request);
    return request.future;
  }

  @override
  Future<List<Map<String, dynamic>>> getMessageThread(
    String channelId,
    String messageId, {
    int skip = 0,
    int limit = 50,
  }) {
    final request = Completer<List<Map<String, dynamic>>>();
    _threadRequests.add(request);
    return request.future;
  }

  void completeMessages(int requestIndex, List<Map<String, dynamic>> messages) {
    _messageRequests[requestIndex].complete(messages);
  }

  void completeThread(int requestIndex, List<Map<String, dynamic>> messages) {
    _threadRequests[requestIndex].complete(messages);
  }
}

class _MutableValue<T> extends Notifier<T> {
  _MutableValue(this.initial);

  final T initial;

  @override
  T build() => initial;

  void set(T value) => state = value;
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('waitFor timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
