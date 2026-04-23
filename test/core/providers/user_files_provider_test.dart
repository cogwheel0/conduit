import 'package:checks/checks.dart';
import 'package:conduit/core/models/file_info.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UserFiles', () {
    test('propagates the initial page failure', () async {
      final api = _FakeUserFilesApiService(firstPageError: StateError('boom'));
      final container = _container(api);
      addTearDown(container.dispose);

      await check(
        container.read(userFilesProvider.future),
      ).throws<StateError>();
      check(api.requestedPages).deepEquals([1]);
    });

    test(
      'returns the first page immediately and backfills remaining pages',
      () async {
        final api = _FakeUserFilesApiService(
          responses: {
            1: (
              items: [_fileInfo('file-1', updatedAt: DateTime.utc(2026, 1, 1))],
              total: 3,
              isPaginated: true,
            ),
            2: (
              items: [
                _fileInfo('file-2', updatedAt: DateTime.utc(2026, 1, 2)),
                _fileInfo('file-3', updatedAt: DateTime.utc(2026, 1, 3)),
              ],
              total: 3,
              isPaginated: true,
            ),
          },
          pageDelays: {2: const Duration(milliseconds: 10)},
        );
        final container = _container(api);
        addTearDown(container.dispose);

        final initialFiles = await container.read(userFilesProvider.future);

        check(
          initialFiles.map((file) => file.id).toList(),
        ).deepEquals(['file-1']);
        check(
          container.read(userFilesProvider).requireValue.map((file) => file.id),
        ).deepEquals(['file-1']);

        await Future<void>.delayed(const Duration(milliseconds: 30));

        final allFiles = container.read(userFilesProvider).requireValue;
        check(
          allFiles.map((file) => file.id).toList(),
        ).deepEquals(['file-3', 'file-2', 'file-1']);
        check(api.requestedPages).deepEquals([1, 2]);
      },
    );

    test(
      'ignores pre-load upserts until the first server fetch completes',
      () async {
        final api = _FakeUserFilesApiService(
          responses: {
            1: (
              items: [
                _fileInfo('server-1', updatedAt: DateTime.utc(2026, 1, 1)),
                _fileInfo('server-2', updatedAt: DateTime.utc(2026, 1, 2)),
              ],
              total: 2,
              isPaginated: true,
            ),
          },
        );
        final container = _container(api);
        addTearDown(container.dispose);

        container
            .read(userFilesProvider.notifier)
            .upsert(
              _fileInfo('local-only', updatedAt: DateTime.utc(2026, 2, 1)),
            );

        final files = await container.read(userFilesProvider.future);

        check(
          files.map((file) => file.id).toList(),
        ).deepEquals(['server-2', 'server-1']);
        check(api.requestedPages).deepEquals([1]);
      },
    );

    test('upsert updates an already loaded file list', () async {
      final api = _FakeUserFilesApiService(
        responses: {
          1: (
            items: [_fileInfo('server-1', updatedAt: DateTime.utc(2026, 1, 1))],
            total: 1,
            isPaginated: true,
          ),
        },
      );
      final container = _container(api);
      addTearDown(container.dispose);

      await container.read(userFilesProvider.future);

      container
          .read(userFilesProvider.notifier)
          .upsert(_fileInfo('local-new', updatedAt: DateTime.utc(2026, 2, 1)));

      check(
        container.read(userFilesProvider).requireValue.map((file) => file.id),
      ).deepEquals(['local-new', 'server-1']);
    });

    test('searchUserFiles keeps paging until the final batch', () async {
      final api = _FakeUserFilesApiService(
        searchResponses: {
          0: List<FileInfo>.generate(
            100,
            (index) => _fileInfo(
              'file-$index',
              updatedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
            ),
          ),
          100: [_fileInfo('file-tail', updatedAt: DateTime.utc(2026, 2, 1))],
        },
      );
      final container = _container(api);
      addTearDown(container.dispose);

      final files = await container.read(
        searchUserFilesProvider('file').future,
      );

      check(files).has((it) => it.length, 'length').equals(101);
      check(files.first.id).equals('file-tail');
      check(api.searchRequests).deepEquals(const [
        (query: 'file', limit: 100, offset: 0),
        (query: 'file', limit: 100, offset: 100),
      ]);
    });
  });
}

ProviderContainer _container(ApiService api) {
  return ProviderContainer(
    overrides: [
      isAuthenticatedProvider2.overrideWithValue(true),
      apiServiceProvider.overrideWithValue(api),
    ],
  );
}

class _FakeUserFilesApiService extends ApiService {
  _FakeUserFilesApiService({
    this.responses = const {},
    this.searchResponses = const {},
    this.pageDelays = const {},
    this.firstPageError,
  }) : super(
         serverConfig: const ServerConfig(
           id: 'test',
           name: 'Test',
           url: 'https://example.com',
         ),
         workerManager: WorkerManager(),
       );

  final Map<int, ({List<FileInfo> items, int? total, bool isPaginated})>
  responses;
  final Map<int, List<FileInfo>> searchResponses;
  final Map<int, Duration> pageDelays;
  final Object? firstPageError;
  final requestedPages = <int>[];
  final searchRequests = <({String query, int limit, int offset})>[];

  @override
  Future<({List<FileInfo> items, int? total, bool isPaginated})>
  getUserFilesPage({int page = 1}) async {
    requestedPages.add(page);

    final delay = pageDelays[page];
    if (delay != null) {
      await Future<void>.delayed(delay);
    }

    if (page == 1 && firstPageError != null) {
      throw firstPageError!;
    }

    return responses[page] ??
        (items: const <FileInfo>[], total: null, isPaginated: true);
  }

  @override
  Future<List<FileInfo>> searchFiles({
    String? query,
    String? contentType,
    int? limit,
    int? offset,
  }) async {
    final resolvedQuery = query?.trim() ?? '';
    final resolvedLimit = limit ?? 100;
    final resolvedOffset = offset ?? 0;
    searchRequests.add((
      query: resolvedQuery,
      limit: resolvedLimit,
      offset: resolvedOffset,
    ));
    return searchResponses[resolvedOffset] ?? const <FileInfo>[];
  }
}

FileInfo _fileInfo(String id, {required DateTime updatedAt}) {
  return FileInfo(
    id: id,
    filename: '$id.txt',
    originalFilename: '$id.txt',
    size: 128,
    mimeType: 'text/plain',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: updatedAt,
  );
}
