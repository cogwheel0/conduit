import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  for (final kind in TerminalServerKind.values) {
    group('${kind.name} file previews', () {
      late HttpServer http;
      late ApiService api;
      late TerminalService service;
      late TerminalServerInfo terminal;
      final requests = <HttpRequest>[];
      late String contentType;
      late List<int> body;
      var status = HttpStatus.ok;

      setUp(() async {
        requests.clear();
        contentType = 'application/pdf';
        body = utf8.encode('%PDF-1.7\nsynthetic preview');
        status = HttpStatus.ok;
        http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        http.listen((request) async {
          requests.add(request);
          request.response.statusCode = status;
          request.response.headers.set('content-type', contentType);
          request.response.add(body);
          await request.response.close();
        });
        final url = 'http://127.0.0.1:${http.port}';
        api = ApiService(
          serverConfig: ServerConfig(id: 'preview', name: 'Preview', url: url),
          authToken: 'account-token',
          workerManager: WorkerManager(),
        );
        service = TerminalService(api);
        terminal = TerminalServerInfo(
          kind: kind,
          selectionId: 'terminal',
          systemServerId: kind == TerminalServerKind.system
              ? 'workspace'
              : null,
          baseUrl: Uri.parse(url),
          apiKey: kind == TerminalServerKind.direct ? 'terminal-key' : null,
        );
      });

      tearDown(() async {
        api.dispose();
        await http.close(force: true);
      });

      test(
        'PPTX and DOCX request fresh PDF previews with existing auth and scope',
        () async {
          for (final name in ['slides.pptx', 'report.DOCX', 'slides.pptx']) {
            body = utf8.encode('%PDF-1.7\nrevision ${requests.length + 1}');
            final result = await service.readFile(
              terminal,
              '/Documents/$name',
              sessionScopeId: 'chat-1',
            );
            expect(result.fileName, name);
            expect(result.contentType, 'application/pdf');
            expect(result.bytes, body);
            expect(result.isText, isFalse);
          }
          expect(requests, hasLength(3));
          for (final request in requests) {
            expect(
              request.uri.path,
              kind == TerminalServerKind.system
                  ? '/api/v1/terminals/workspace/files/view'
                  : '/files/view',
            );
            expect(request.uri.queryParameters['preview'], 'true');
            expect(request.headers.value('x-session-id'), 'chat-1');
            expect(
              request.headers.value('authorization'),
              kind == TerminalServerKind.system
                  ? 'Bearer account-token'
                  : 'Bearer terminal-key',
            );
          }
          expect(requests.map((r) => r.uri.queryParameters['path']), [
            '/Documents/slides.pptx',
            '/Documents/report.DOCX',
            '/Documents/slides.pptx',
          ]);
        },
      );

      test('PDF previews fetch original bytes instead of extracted text', () async {
        for (final name in ['report.pdf', 'report.PDF', 'report.pdf']) {
          final result = await service.readFile(
            terminal,
            '/Documents/$name',
            sessionScopeId: 'chat-1',
          );
          expect(result.bytes, body);
          expect(result.fileName, name);
        }
        expect(requests, hasLength(3));
        for (final request in requests) {
          expect(request.uri.path, endsWith('/files/view'));
          expect(request.uri.queryParameters.containsKey('preview'), isFalse);
          expect(request.headers.value('x-session-id'), 'chat-1');
        }
      });

      test('unavailable conversion preserves the binary fallback and original download', () async {
        contentType = 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
        body = [80, 75, 3, 4, 0, 255];
        final preview = await service.readFile(
          terminal,
          '/slides.pptx',
          sessionScopeId: 'chat-1',
        );
        expect(preview.bytes, body);
        expect(preview.isText, isFalse);
        final original = await service.downloadFile(
          terminal,
          '/slides.pptx',
          sessionScopeId: 'chat-1',
        );
        expect(original.fileName, 'slides.pptx');
        expect(original.bytes, body);
        expect(requests.first.uri.queryParameters['preview'], 'true');
        expect(requests.last.uri.queryParameters, {'path': '/slides.pptx'});
      });

      test(
        'ordinary files retain the existing read endpoint and text handling',
        () async {
          contentType = 'application/json';
          body = utf8.encode(jsonEncode({'content': 'synthetic text'}));
          final text = await service.readFile(
            terminal,
            '/notes.txt',
            sessionScopeId: 'chat-1',
          );
          expect(text.text, 'synthetic text');
          expect(requests.single.uri.path, endsWith('/files/read'));
          expect(requests.single.uri.queryParameters, {'path': '/notes.txt'});
        },
      );

      test(
        'authorization failures still reach the existing error handler',
        () async {
          status = HttpStatus.forbidden;
          await expectLater(
            service.readFile(
              terminal,
              '/slides.pptx',
              sessionScopeId: 'chat-1',
            ),
            throwsA(
              isA<DioException>().having(
                (e) => e.response?.statusCode,
                'status',
                403,
              ),
            ),
          );
          expect(requests, hasLength(1));
        },
      );
    });
  }
}
