import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/web_embed/web_embed_media.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  final server = Uri.parse('https://chat.example.test/');

  group('webEmbedServerMediaUrl', () {
    test('resolves a path against the server', () {
      check(
        webEmbedServerMediaUrl('/api/v1/files/f1/content', server).toString(),
      ).equals('https://chat.example.test/api/v1/files/f1/content');
      check(
        webEmbedServerMediaUrl(
          'clips/a.mp3',
          Uri.parse('https://chat.example.test/owui/'),
        ).toString(),
      ).equals('https://chat.example.test/owui/clips/a.mp3');
    });

    test('keeps an address on the same server', () {
      for (final src in [
        'https://chat.example.test/media/a.wav',
        'HTTPS://Chat.Example.Test:443/media/a.wav',
        '//chat.example.test/media/a.wav',
      ]) {
        check(
          because: src,
          webEmbedServerMediaUrl(src, server).toString(),
        ).equals('https://chat.example.test/media/a.wav');
      }
    });

    test('refuses every other address', () {
      for (final src in [
        'https://other.example.test/a.mp3',
        '//other.example.test/a.mp3',
        'http://chat.example.test/a.mp3',
        'https://chat.example.test:8443/a.mp3',
        'https://someone@chat.example.test/a.mp3',
        'data:audio/wav;base64,AAAA',
        'blob:https://chat.example.test/1',
        'javascript:alert(1)',
        'ftp://chat.example.test/a.mp3',
        '',
        '   ',
      ]) {
        check(because: src, webEmbedServerMediaUrl(src, server)).isNull();
      }
    });
  });

  group('rewriteWebEmbedMediaSources', () {
    test('passes only audio, video and source addresses through', () {
      const html =
          '<img src="/a.png"><audio controls src="/b.wav"></audio>'
          '<video><source src=\'/c.mp4\' type="video/mp4"></video>'
          '<script src="/d.js"></script><SOURCE SRC=/e.ogg>'
          '<a href="/f.mp3">f</a><audio data-src="/g.mp3"></audio>';
      final seen = <String>[];
      final out = rewriteWebEmbedMediaSources(html, (src) {
        seen.add(src);
        return src == '/b.wav' ? 'data:audio/wav;base64,QQ==' : null;
      });
      check(seen).deepEquals(['/b.wav', '/c.mp4', '/e.ogg']);
      check(out).equals(
        html.replaceFirst('src="/b.wav"', 'src="data:audio/wav;base64,QQ=="'),
      );
    });

    test('decodes entities in the address and escapes the replacement', () {
      final seen = <String>[];
      final out = rewriteWebEmbedMediaSources(
        '<audio src="/x?a=1&amp;b=2"></audio>',
        (src) {
          seen.add(src);
          return 'https://chat.example.test/x?a=1&b="2"';
        },
      );
      check(seen).deepEquals(['/x?a=1&b=2']);
      check(out).equals(
        '<audio src="https://chat.example.test/x?a=1&amp;b=&quot;2&quot;">'
        '</audio>',
      );
    });
  });

  group('inlineWebEmbedServerMedia', () {
    late _Server adapter;
    late Dio dio;

    setUp(() {
      adapter = _Server();
      dio = Dio()..httpClientAdapter = adapter;
    });

    test('inlines the server\'s audio and leaves other sites alone', () async {
      adapter.bodies['/clip.wav'] = ([1, 2, 3], 'audio/wav; charset=binary');
      final out = await inlineWebEmbedServerMedia(
        '<audio src="/clip.wav"></audio>'
        '<audio src="https://other.example.test/x.mp3"></audio>',
        serverBase: server,
        dio: dio,
      );
      check(out).equals(
        '<audio src="data:audio/wav;base64,${base64Encode([1, 2, 3])}">'
        '</audio><audio src="https://other.example.test/x.mp3"></audio>',
      );
      check(adapter.requests.map((r) => r.uri.toString()))
          .deepEquals(['https://chat.example.test/clip.wav']);
    });

    test('points at the server what it cannot inline', () async {
      adapter.bodies['/page'] = ([60, 112, 62], 'text/html');
      adapter.bodies['/big.mp4'] = (List.filled(9, 0), 'video/mp4');
      final out = await inlineWebEmbedServerMedia(
        '<video src="/page"></video><video src="/big.mp4"></video>'
        '<audio src="/missing.mp3"></audio>',
        serverBase: server,
        dio: dio,
        maxBytes: 8,
      );
      check(out).equals(
        '<video src="https://chat.example.test/page"></video>'
        '<video src="https://chat.example.test/big.mp4"></video>'
        '<audio src="https://chat.example.test/missing.mp3"></audio>',
      );
    });

    test('fetches a repeated address once', () async {
      adapter.bodies['/clip.mp3'] = ([9], 'audio/mpeg');
      await inlineWebEmbedServerMedia(
        '<audio src="/clip.mp3"></audio><audio src="/clip.mp3"></audio>',
        serverBase: server,
        dio: dio,
      );
      check(adapter.requests).length.equals(1);
    });
  });
}

final class _Server implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <String, (List<int>, String)>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = bodies[options.uri.path];
    if (body == null) return ResponseBody.fromString('', 404);
    return ResponseBody.fromBytes(
      body.$1,
      200,
      headers: {
        Headers.contentTypeHeader: [body.$2],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
