import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// `GET /api/v1/folders/{id}/shared/chats?page=N` serves 10 chats per page
/// with a `has_more` flag (`routers/folders.py:get_shared_folder_chats`).
/// [ApiService.getSharedFolderChats] walks every page so a folder larger than
/// one page is listed in full.
void main() {
  test('walks pages until has_more is false', () async {
    final adapter = _PagedAdapter({
      1: (['a', 'b'], true),
      2: (['c'], false),
      3: (['never'], false),
    });
    final api = _buildApi(adapter);

    final chats = await api.getSharedFolderChats('f1');

    check(chats.map((c) => c['id'])).deepEquals(['a', 'b', 'c']);
    check(adapter.pagesRequested).deepEquals([1, 2]);
  });

  test(
    'stops at maxPages even when the server keeps saying has_more',
    () async {
      final adapter = _PagedAdapter({
        for (var p = 1; p <= 5; p++) p: (['p$p'], true),
      });
      final api = _buildApi(adapter);

      final chats = await api.getSharedFolderChats('f1', maxPages: 3);

      check(chats.map((c) => c['id'])).deepEquals(['p1', 'p2', 'p3']);
    },
  );

  test('a missing chats key yields an empty list', () async {
    final api = _buildApi(_PagedAdapter(const {}));

    final chats = await api.getSharedFolderChats('f1');

    check(chats).isEmpty();
  });
}

class _PagedAdapter implements HttpClientAdapter {
  _PagedAdapter(this.pages);

  /// page -> (chat ids, has_more). A page absent here answers `{}`.
  final Map<int, (List<String>, bool)> pages;
  final List<int> pagesRequested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final page = int.parse(options.uri.queryParameters['page']!);
    pagesRequested.add(page);
    final entry = pages[page];
    final body = entry == null
        ? const <String, Object?>{}
        : {
            'chats': [
              for (final id in entry.$1)
                {'id': id, 'title': id, 'updated_at': 1, 'created_at': 1},
            ],
            'has_more': entry.$2,
            'folder_permission': 'read',
          };
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(body)))),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiService _buildApi(HttpClientAdapter adapter) {
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test',
      url: 'http://localhost:0',
    ),
    workerManager: WorkerManager(),
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return service;
}
