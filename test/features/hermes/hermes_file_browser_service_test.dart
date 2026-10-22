import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_file_entry.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_json_guard.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Routes extends Interceptor {
  final requests = <RequestOptions>[];
  bool locked = false;
  bool conflict = false;
  String? hermesHome = '/home/person/.hermes';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.uri.path.endsWith('/api/status')) {
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 200,
          data: utf8.encode('{"auth_required":false}'),
        ),
      );
      return;
    }
    requests.add(options);
    if (options.uri.path.endsWith('/api/profiles')) {
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 200,
          data: utf8.encode(
            jsonEncode({
              'profiles': [
                if (hermesHome != null)
                  {'name': 'default', 'is_default': true, 'path': hermesHome},
              ],
            }),
          ),
        ),
      );
      return;
    }
    if (conflict && options.uri.path.endsWith('/api/files/upload')) {
      handler.reject(
        DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 409),
        ),
      );
      return;
    }
    final path =
        options.uri.queryParameters['path'] ??
        (locked ? '/data' : '/home/person');
    final data = options.uri.path.endsWith('/api/files/read')
        ? {'data_url': 'data:text/plain;base64,aGk='}
        : {
            'path': path,
            'parent': path == '/data' ? null : '/home',
            'can_change_path': !locked,
            'locked_root': locked ? '/data' : null,
            'entries': path == '/home/person'
                ? [
                    {
                      'name': '.hermes',
                      'path': '/home/person/.hermes',
                      'is_directory': true,
                    },
                  ]
                : [],
            'ok': true,
          };
    handler.resolve(
      Response(
        requestOptions: options,
        statusCode: 200,
        data: utf8.encode(jsonEncode(data)),
      ),
    );
  }
}

class _OversizedStream implements HttpClientAdapter {
  int chunksRead = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.endsWith('/api/status')) {
      return ResponseBody.fromString('{"auth_required":false}', 200);
    }
    Stream<Uint8List> chunks() async* {
      for (var i = 0; i < 256; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        chunksRead++;
        yield Uint8List(64 * 1024);
      }
    }

    return ResponseBody(
      chunks(),
      200,
      headers: {
        Headers.contentLengthHeader: ['16777216'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Routes routes;
  late HermesDesktopApiService service;
  setUp(() {
    routes = _Routes();
    service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'http://hermes.example:8642/server',
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.legacyToken,
        desktopCredentials: HermesDesktopCredentials(legacyToken: 'test-token'),
      ),
      dio: Dio()..interceptors.add(routes),
    );
  });
  tearDown(() => service.close());

  test(
    'starts in the server Hermes directory and preserves the endpoint prefix',
    () async {
      expect((await service.browseFiles()).path, '/home/person/.hermes');
      expect(routes.requests.map((r) => r.uri.path), [
        '/server/api/files',
        '/server/api/profiles',
        '/server/api/files',
      ]);
      expect(
        routes.requests.last.uri.queryParameters['path'],
        '/home/person/.hermes',
      );
      expect(
        routes.requests.last.headers['X-Hermes-Session-Token'],
        'test-token',
      );
    },
  );

  test('respects the locked root returned by hosted Hermes', () async {
    routes.locked = true;
    final directory = await service.browseFiles();
    expect(directory.root, '/data');
    expect(directory.parent, isNull);
    expect(directory.canChangePath, isFalse);
    expect(routes.requests, hasLength(1));
  });

  test('discovers a nonstandard Hermes home through authenticated profile metadata', () async {
    routes.hermesHome = '/custom/hermes-data';
    expect((await service.browseFiles()).path, '/custom/hermes-data');
    expect(
      routes.requests.last.uri.queryParameters['path'],
      '/custom/hermes-data',
    );
  });

  test(
    'older profile metadata falls back to the server home listing',
    () async {
      routes.hermesHome = null;
      expect((await service.browseFiles()).path, '/home/person/.hermes');
    },
  );

  test(
    'browses a selected server folder without inspecting sessions',
    () async {
      expect(
        (await service.browseFiles(path: '/projects/project one')).path,
        '/projects/project one',
      );
      expect(
        routes.requests.single.uri.queryParameters['path'],
        '/projects/project one',
      );
      expect(routes.requests.single.uri.path, '/server/api/files');
    },
  );

  test('new files use UTF-8 upload with overwrite disabled', () async {
    await service.createFile(
      directory: '/projects',
      name: 'Résumé.md',
      content: 'Hello 🐈',
    );
    final request = routes.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/server/api/files/upload');
    final body = request.data as Map;
    expect(body['path'], '/projects/Résumé.md');
    expect(body['overwrite'], isFalse);
    expect(
      UriData.parse(body['data_url'] as String).contentAsString(),
      'Hello 🐈',
    );
  });

  test('an existing file produces an error with no overwrite retry', () async {
    routes.conflict = true;
    await expectLater(
      service.createFile(
        directory: '/projects',
        name: 'existing.md',
        content: 'new',
      ),
      throwsA(isA<DioException>()),
    );
    expect(routes.requests, hasLength(1));
    expect((routes.requests.single.data as Map)['overwrite'], isFalse);
  });

  test('folder creation uses the managed directory endpoint', () async {
    await service.createDirectory(directory: '/projects/', name: 'Notes');
    expect(routes.requests.single.uri.path, '/server/api/files/mkdir');
    expect(routes.requests.single.data, {'path': '/projects/Notes'});
  });

  test(
    'rejects traversal, separators, and control characters before a request',
    () async {
      for (final name in [
        '..',
        '.',
        '../outside',
        'folder/file',
        r'folder\file',
        'bad\nname',
      ]) {
        await expectLater(
          service.createFile(directory: '/projects', name: name, content: ''),
          throwsArgumentError,
        );
      }
      expect(routes.requests, isEmpty);
    },
  );

  test(
    'file preview uses managed read without a conversation or agent turn',
    () async {
      expect(
        await service.readFileDataUrl('/projects/notes.md'),
        'data:text/plain;base64,aGk=',
      );
      expect(routes.requests.single.uri.path, '/server/api/files/read');
      expect(routes.requests.single.uri.queryParameters, {
        'path': '/projects/notes.md',
      });
    },
  );

  test(
    'oversized preview responses stop before the full body is buffered',
    () async {
      final adapter = _OversizedStream();
      final bounded = HermesDesktopApiService(
        config: service.config,
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(bounded.close);
      await expectLater(
        bounded.readFileDataUrl('/projects/grown-file.txt'),
        throwsA(isA<HermesResponseTooLargeException>()),
      );
      expect(adapter.chunksRead, lessThan(256));
    },
  );

  test('parses file metadata and rejects malformed server responses', () {
    final entry = HermesFileEntry.fromJson({
      'name': 'notes.md',
      'path': '/notes.md',
      'is_directory': false,
      'size': 42,
      'mtime': 1791700000,
    });
    expect(entry.size, 42);
    expect(entry.modifiedAt, isNotNull);
    expect(
      () => HermesDirectory.fromJson({
        'path': '/root',
        'entries': [
          {'name': 'bad', 'path': '/bad', 'is_directory': 'false'},
        ],
      }),
      throwsFormatException,
    );
  });
}
