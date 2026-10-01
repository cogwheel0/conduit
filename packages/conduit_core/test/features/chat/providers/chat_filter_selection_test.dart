// Split from test/features/chat/widgets/composer_overflow_items_test.dart:
// these cases exercise the chat providers' filter selection, not the
// composer widgets.
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:test/test.dart';

const _toggleFilter = ToggleFilter(
  id: 'test-toggle-filter',
  name: 'Test Toggle Filter',
  description: 'Adds a test system instruction.',
);

void main() {
  test('conversation boundary clears selected filters', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedFilterIdsProvider.notifier).set(const [
      'test-toggle-filter',
    ]);

    clearSelectedFiltersForConversationBoundary(container);

    expect(container.read(selectedFilterIdsProvider), isEmpty);
  });

  test('request-time filter selection drops ids absent from the model', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedFilterIdsProvider.notifier).set(const [
      'stale-filter',
      'test-toggle-filter',
    ]);

    final selected = selectedFilterIdsForModel(
      container,
      const Model(id: 'model-1', name: 'Model', filters: [_toggleFilter]),
    );

    expect(selected, ['test-toggle-filter']);
  });

  test('selected filters are emitted as filter_ids in chat requests', () async {
    final adapter = _CapturingAdapter();
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'test',
        name: 'Test Server',
        url: 'http://localhost:9999',
      ),
      workerManager: WorkerManager(),
    );
    api.dio
      ..httpClientAdapter = adapter
      ..interceptors.clear();

    await api.sendMessageSession(
      messages: const [
        {'role': 'user', 'content': 'hello'},
      ],
      model: 'test-model',
      filterIds: const ['test-toggle-filter'],
    );

    final request = adapter.lastRequest;
    expect(request, isNotNull);
    final body = request!.data as Map<String, dynamic>;
    expect(body['filter_ids'], const ['test-toggle-filter']);
  });
}

class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    final body = utf8.encode(
      jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
          },
        ],
      }),
    );
    return ResponseBody(
      Stream.value(Uint8List.fromList(body)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
