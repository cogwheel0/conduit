import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_knowledge_files.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(id: 's', name: 'S', url: 'http://localhost:0');

/// An Open WebUI 0.13 server for one knowledge base: it answers the upload
/// check with [validateStatus], stores uploads, and answers links with
/// [attachStatus]. Every request is recorded as `METHOD path`.
class _KnowledgeServer implements HttpClientAdapter {
  _KnowledgeServer({
    this.validateStatus = 200,
    this.attachStatus = 200,
    this.failUpload,
    this.batchProcessed,
  });

  final int validateStatus;
  final int attachStatus;

  /// The upload, counted from 1, that fails.
  final int? failUpload;

  /// When set, a batch add reports only these uploads as added, with a
  /// warning for the rest, as Open WebUI does for files it fails to process.
  final Set<String>? batchProcessed;
  final requests = <String>[];
  final validations = <Map<String, dynamic>>[];
  var _uploads = 0;

  Iterable<String> get uploads =>
      requests.where((r) => r == 'POST /api/v1/files/');
  Iterable<String> get deletions =>
      requests.where((r) => r.startsWith('DELETE /api/v1/files/'));

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.path;
    requests.add('${options.method} $path');
    if (path.endsWith('/files/validate')) {
      validations.add(Map<String, dynamic>.from(options.data as Map));
      return switch (validateStatus) {
        200 => _json({'status': true}),
        // Servers before 0.13 answer an unknown POST so.
        405 => _json({'detail': 'Method Not Allowed'}, status: 405),
        final status => _json({
          'detail': 'Knowledge base file limit exceeded (2 files maximum).',
        }, status: status),
      };
    }
    if (path == '/api/v1/files/' && options.method == 'POST') {
      if (++_uploads == failUpload) {
        return _json({'detail': 'Upload failed'}, status: 500);
      }
      return _json({'id': 'upload-$_uploads'});
    }
    final processed = batchProcessed;
    if (processed != null && path.endsWith('/files/batch/add')) {
      return _json({
        'id': 'kb-1',
        'name': 'Docs',
        'user_id': 'owner',
        'files': [
          for (final id in processed) {'id': id, 'filename': '$id.txt'},
        ],
        'warnings': {
          'message': 'Some files failed to process',
          'errors': ['upload-2: Unsupported file'],
        },
      });
    }
    if (path.endsWith('/file/add') || path.endsWith('/files/batch/add')) {
      return attachStatus == 200
          ? _json({'id': 'kb-1', 'name': 'Docs', 'user_id': 'owner'})
          : _json({
              'detail': 'Knowledge base file limit exceeded (2 files maximum).',
            }, status: attachStatus);
    }
    if (options.method == 'DELETE') return _json({'ok': true});
    if (path.endsWith('/files/pending')) return _json(<Object>[]);
    if (path.endsWith('/files')) return _json({'items': <Object>[], 'total': 0});
    return _json(<String, dynamic>{});
  }

  ResponseBody _json(Object body, {int status = 200}) => ResponseBody(
    Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(body)))),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

Future<ProviderContainer> _container(_KnowledgeServer server) async {
  final api = ApiService(serverConfig: _server, workerManager: WorkerManager())
    ..dio.httpClientAdapter = server;
  api.dio.interceptors.clear();
  final container = ProviderContainer(
    overrides: [
      apiServiceProvider.overrideWithValue(api),
      activeServerProvider.overrideWith((ref) async => _server),
      currentUserProvider2.overrideWithValue(
        const User(id: 'owner', username: 'o', email: 'o@e.com', role: 'user'),
      ),
      authTokenProvider3.overrideWithValue('token'),
    ],
  );
  await container.read(activeServerProvider.future);
  container.listen(workspaceKnowledgeFilesProvider('kb-1'), (_, _) {});
  await container.read(workspaceKnowledgeFilesProvider('kb-1').future);
  return container;
}

WorkspaceUploadSource _file(String name, int size) =>
    (name: name, size: size, read: () async => List<int>.filled(size, 1));

void main() {
  group('knowledge base file limits on upload (Open WebUI 0.13)', () {
    test('a batch is checked by count and largest size before any upload', () async {
      final server = _KnowledgeServer();
      final container = await _container(server);
      addTearDown(container.dispose);

      await container
          .read(workspaceKnowledgeFilesProvider('kb-1').notifier)
          .uploadMany([_file('a.txt', 3), _file('b.txt', 7)]);

      check(server.validations.single).deepEquals({
        'count': 2,
        'file_size': 7,
        'removed_file_ids': <String>[],
      });
      final validateAt = server.requests.indexWhere(
        (r) => r.endsWith('/files/validate'),
      );
      final firstUpload = server.requests.indexOf('POST /api/v1/files/');
      check(validateAt).isLessThan(firstUpload);
      check(server.uploads).length.equals(2);
      check(server.requests).contains(
        'POST /api/v1/knowledge/kb-1/files/batch/add',
      );
    });

    test('a refused batch uploads nothing and says why', () async {
      final server = _KnowledgeServer(validateStatus: 400);
      final container = await _container(server);
      addTearDown(container.dispose);

      await check(
        container
            .read(workspaceKnowledgeFilesProvider('kb-1').notifier)
            .uploadMany([_file('a.txt', 3), _file('b.txt', 7), _file('c', 1)]),
      ).throws<KnowledgeUploadRefused>(
        (it) => it.has((e) => e.reason, 'reason').contains('2 files maximum'),
      );
      check(server.uploads).isEmpty();
    });

    test('files the server still refuses to link are deleted again', () async {
      final server = _KnowledgeServer(attachStatus: 400);
      final container = await _container(server);
      addTearDown(container.dispose);

      await check(
        container
            .read(workspaceKnowledgeFilesProvider('kb-1').notifier)
            .uploadMany([_file('a.txt', 3), _file('b.txt', 7)]),
      ).throws<KnowledgeUploadRefused>();
      check(server.deletions.toList()).deepEquals([
        'DELETE /api/v1/files/upload-1',
        'DELETE /api/v1/files/upload-2',
      ]);
    });

    test('a single upload is checked too, and cleaned up on refusal', () async {
      final server = _KnowledgeServer(attachStatus: 413);
      final container = await _container(server);
      addTearDown(container.dispose);

      await check(
        container
            .read(workspaceKnowledgeFilesProvider('kb-1').notifier)
            .uploadBytes('a.txt', const [1, 2, 3]),
      ).throws<KnowledgeUploadRefused>();
      check(server.validations.single['file_size']).equals(3);
      check(server.deletions.toList()).deepEquals([
        'DELETE /api/v1/files/upload-1',
      ]);
    });

    test('a server before 0.13 has no check, and the upload goes on', () async {
      final server = _KnowledgeServer(validateStatus: 405);
      final container = await _container(server);
      addTearDown(container.dispose);
      final files = container.read(
        workspaceKnowledgeFilesProvider('kb-1').notifier,
      );

      await files.uploadMany([_file('a.txt', 3), _file('b.txt', 7)]);
      await files.uploadBytes('c.txt', const [1]);

      check(server.uploads).length.equals(3);
      // Asked once, then left alone.
      check(server.validations).length.equals(1);
    });

    test('files the server could not process are deleted again', () async {
      final server = _KnowledgeServer(batchProcessed: {'upload-1'});
      final container = await _container(server);
      addTearDown(container.dispose);

      await check(
        container
            .read(workspaceKnowledgeFilesProvider('kb-1').notifier)
            .uploadMany([_file('a.txt', 3), _file('b.txt', 7)]),
      ).throws<KnowledgeUploadRefused>(
        (it) => it.has((e) => e.reason, 'reason').contains('Unsupported file'),
      );
      check(server.deletions.toList()).deepEquals([
        'DELETE /api/v1/files/upload-2',
      ]);
    });

    test('an upload that fails midway deletes the ones before it', () async {
      final server = _KnowledgeServer(failUpload: 2);
      final container = await _container(server);
      addTearDown(container.dispose);

      await check(
        container
            .read(workspaceKnowledgeFilesProvider('kb-1').notifier)
            .uploadMany([_file('a.txt', 3), _file('b.txt', 7), _file('c', 1)]),
      ).throws();
      check(server.deletions.toList()).deepEquals([
        'DELETE /api/v1/files/upload-1',
      ]);
      check(
        server.requests.where((r) => r.endsWith('/batch/add')),
      ).isEmpty();
    });

    test('a full base still takes a file it already holds', () async {
      // The server lets a base re-link one of its own files at its limit;
      // nothing is uploaded, so there is nothing to check first.
      final server = _KnowledgeServer(validateStatus: 400);
      final container = await _container(server);
      addTearDown(container.dispose);

      await container
          .read(workspaceKnowledgeFilesProvider('kb-1').notifier)
          .attachExisting('already-there');

      check(server.validations).isEmpty();
      check(server.requests).contains('POST /api/v1/knowledge/kb-1/file/add');
    });

    test("the user's own file is never deleted when linking it fails", () async {
      final server = _KnowledgeServer(attachStatus: 400);
      final container = await _container(server);
      addTearDown(container.dispose);

      await check(
        container
            .read(workspaceKnowledgeFilesProvider('kb-1').notifier)
            .attachExisting('mine'),
      ).throws<KnowledgeUploadRefused>();
      check(server.deletions).isEmpty();
    });
  });
}
