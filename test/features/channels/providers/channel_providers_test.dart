import 'dart:async';

import 'package:conduit/core/models/server_config.dart';
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
