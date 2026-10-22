import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_media.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_media_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const wav = HermesMediaReference(
  path: '/home/person/Conduit/zoey-demo.wav',
  name: 'zoey-demo.wav',
);

class _BinaryServer implements HttpClientAdapter {
  _BinaryServer(this.bytes);
  final Uint8List bytes;
  final requests = <RequestOptions>[];
  int status = 200;
  int? length;
  String mime = 'audio/wav';
  Duration delay = Duration.zero;
  final firstChunk = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.path.endsWith('/api/status'))
      return ResponseBody.fromString('{"auth_required":false}', 200);
    if (options.uri.path.endsWith('/read-data-url') ||
        options.uri.path.endsWith('/api/files/read')) {
      return ResponseBody.fromString(
        jsonEncode({'dataUrl': 'data:audio/wav;base64,${base64Encode(bytes)}'}),
        200,
      );
    }
    Stream<Uint8List> chunks() async* {
      for (var offset = 0; offset < bytes.length; offset += 8192) {
        if (delay != Duration.zero) await Future<void>.delayed(delay);
        if (!firstChunk.isCompleted) firstChunk.complete();
        yield Uint8List.sublistView(
          bytes,
          offset,
          (offset + 8192).clamp(0, bytes.length),
        );
      }
    }

    return ResponseBody(
      chunks(),
      status,
      headers: {
        Headers.contentLengthHeader: ['${length ?? bytes.length}'],
        Headers.contentTypeHeader: [mime],
        if (status == 302) 'location': ['https://unrelated.example/file.wav'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Dashboard
    implements HermesDashboardBridge, HermesDashboardTransferBridge {
  final urls = <Uri>[];
  @override
  Future<Map<String, String>> transferHeaders(Uri url) async {
    urls.add(url);
    return {'Cookie': 'test-session=owned'};
  }

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
  }) async => (status: 200, body: '{}');
  @override
  Future<void> reload() async {}
  @override
  Future<void> close() async {}
}

Uint8List _wavFixture() {
  final bytes = Uint8List(483884);
  final header = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  header.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 24000, Endian.little);
  header.setUint32(28, 48000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  header.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

void main() {
  late Directory temp;
  late _BinaryServer server;
  late HermesDesktopApiService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('conduit-media-test-');
    server = _BinaryServer(_wavFixture());
    service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'http://hermes.example:8642/server',
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.legacyToken,
        desktopCredentials: HermesDesktopCredentials(legacyToken: 'test-token'),
      ),
      dio: Dio()..httpClientAdapter = server,
    );
  });
  tearDown(() async {
    service.close();
    await temp.delete(recursive: true);
  });

  test('exact WAV original streams with prefix, owner, and credentials; bytes stay intact', () async {
    final file = File('${temp.path}/audio.wav');
    var finalReceived = 0;
    await service.downloadMedia(
      wav,
      file.path,
      sessionId: 'session-A',
      profile: 'bot-a',
      onProgress: (n, total) => finalReceived = n,
    );
    expect(await file.readAsBytes(), server.bytes);
    expect(finalReceived, 483884);
    final request = server.requests.last;
    expect(request.uri.path, '/server/api/fs/download');
    expect(request.uri.queryParameters, {
      'path': wav.path,
      'session_id': 'session-A',
      'profile': 'bot-a',
    });
    expect(request.headers['X-Hermes-Session-Token'], 'test-token');
    expect(request.followRedirects, isFalse);
    expect(await File('${file.path}.part').exists(), isFalse);
  });
  test(
    'legacy small preview fallback still returns the exact original',
    () async {
      server.status = 404;
      final file = File('${temp.path}/fallback.wav');
      await service.downloadMedia(wav, file.path, sessionId: 'session-A');
      expect(await file.readAsBytes(), server.bytes);
      expect(server.requests.last.uri.path, '/server/api/fs/read-data-url');
      expect(
        server.requests.last.uri.queryParameters['session_id'],
        'session-A',
      );
    },
  );
  const fixture = String.fromEnvironment('CONDUIT_MEDIA_FIXTURE');
  test(
    'user-provided WAV keeps its exact bytes through the download path',
    () async {
      final actual = await File(fixture).readAsBytes();
      server = _BinaryServer(actual);
      final dio = Dio()..httpClientAdapter = server;
      final sampleService = HermesDesktopApiService(
        config: service.config,
        dio: dio,
      );
      try {
        final file = File('${temp.path}/original.wav');
        await sampleService.downloadMedia(wav, file.path);
        expect(await file.readAsBytes(), actual);
        expect(actual.length, 483884);
      } finally {
        sampleService.close();
      }
    },
    skip: fixture.isEmpty
        ? 'Private sample is provided only for local verification.'
        : false,
  );
  test(
    'oversized content length is rejected before writing a final file',
    () async {
      server.length = kMaxHermesMediaDownloadBytes + 1;
      final path = '${temp.path}/too-big.wav';
      await expectLater(
        service.downloadMedia(wav, path),
        throwsFormatException,
      );
      expect(await File(path).exists(), isFalse);
      expect(await File('$path.part').exists(), isFalse);
    },
  );
  test('truncated response cannot become a cached original', () async {
    server.length = server.bytes.length + 8;
    final path = '${temp.path}/truncated.wav';
    await expectLater(service.downloadMedia(wav, path), throwsA(anything));
    expect(await File(path).exists(), isFalse);
    expect(await File('$path.part').exists(), isFalse);
  });
  test(
    'cancellation removes partial bytes and does not publish a file',
    () async {
      server.delay = const Duration(milliseconds: 2);
      final cancel = CancelToken();
      final path = '${temp.path}/cancelled.wav';
      final pending = service.downloadMedia(
        wav,
        path,
        cancelToken: cancel,
        onProgress: (n, _) {
          if (n > 8192) cancel.cancel();
        },
      );
      await expectLater(pending, throwsA(isA<DioException>()));
      expect(await File(path).exists(), isFalse);
      expect(await File('$path.part').exists(), isFalse);
    },
  );
  test('binary download never follows a credential-bearing redirect', () async {
    server.status = 302;
    await expectLater(
      service.downloadMedia(wav, '${temp.path}/redirect.wav'),
      throwsA(isA<DioException>()),
    );
    expect(
      server.requests.every((r) => r.uri.host == 'hermes.example'),
      isTrue,
    );
  });
  test('HTML login response cannot masquerade as an audio file', () async {
    server.mime = 'text/html; charset=utf-8';
    await expectLater(
      service.downloadMedia(wav, '${temp.path}/login.wav'),
      throwsFormatException,
    );
  });
  test(
    'dashboard cookie transfer is issued only for the owned gateway',
    () async {
      final dashboard = _Dashboard();
      final cookieService = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example/server',
          mode: HermesBackendMode.desktopGateway,
          desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
        ),
        dio: Dio()..httpClientAdapter = server,
        dashboardBridgeFactory: ({required root, required accessHeaders}) =>
            dashboard,
      );
      try {
        await cookieService.downloadMedia(wav, '${temp.path}/cookie.wav');
        expect(dashboard.urls.single.host, 'hermes.example');
        expect(server.requests.last.headers['Cookie'], 'test-session=owned');
        expect(server.requests.last.followRedirects, isFalse);
      } finally {
        cookieService.close();
      }
    },
  );
  test('remote URL and invalid owner are rejected before requests', () async {
    await expectLater(
      service.downloadMedia(
        const HermesMediaReference(
          path: 'https://elsewhere/file.wav',
          name: 'file.wav',
        ),
        '${temp.path}/remote',
      ),
      throwsArgumentError,
    );
    await expectLater(
      service.downloadMedia(wav, '${temp.path}/bad', profile: '../other'),
      throwsArgumentError,
    );
    expect(server.requests, isEmpty);
  });

  test(
    'recognizes old WAV reply, explicit media and structured descriptors once',
    () {
      final refs = hermesMediaReferences(
        'Copied to `${wav.path}`.\nMEDIA:"${wav.path}"',
        files: [
          {'path': wav.path, 'name': wav.name},
        ],
      );
      expect(refs.length, 1);
      expect(refs.single.kind, HermesMediaKind.audio);
      expect(
        HermesMediaReference.fromPath('file:///home/person/a%20b.wav')?.name,
        'a b.wav',
      );
      expect(HermesMediaReference.fromPath('file://other/home/a.wav'), isNull);
      expect(HermesMediaReference.fromPath('/home/person/a\n.wav'), isNull);
      expect(
        hermesMediaReferences(
          '`/usr/bin/run.sh` [remote](https://example.com/audio.wav)',
        ),
        isEmpty,
      );
      expect(
        hermesVisibleMediaText('Here it is\nMEDIA:"${wav.path}"'),
        'Here it is',
      );
    },
  );
  test('typed assistant attachments survive history without persisting inline bytes or trusting user metadata', () {
    final messages = hermesMessagesToChatMessages([
      {
        'id': 'a',
        'role': 'assistant',
        'content': [
          {
            'type': 'audio_file',
            'file': {'path': wav.path, 'name': wav.name},
          },
          {'type': 'audio', 'url': 'data:audio/wav;base64,AA=='},
        ],
      },
      {
        'id': 'u',
        'role': 'user',
        'content': 'hello',
        'files': [
          {'path': wav.path, 'name': wav.name},
        ],
      },
    ]);
    expect(messages.first.files!.single['hermes_server_path'], wav.path);
    expect(messages.first.files!.single.containsKey('data'), isFalse);
    expect(messages.last.files, isNull);
    expect(
      HermesMediaReference.fromDescriptor({
        'url': '/api/v1/files/image',
        'name': 'image.png',
      }),
      isNull,
    );
  });
}
