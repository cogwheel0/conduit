import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/web_embed/web_embed_media.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

final _server = Uri.parse('https://chat.example.test');

WebEmbedServerMedia _extract(String html, {Uri? server, int? maxItems}) =>
    extractWebEmbedServerMedia(
      html,
      server: server ?? _server,
      maxItems: maxItems ?? kWebEmbedMaxServerMedia,
    );

void main() {
  group('extractWebEmbedServerMedia', () {
    test('takes audio and video on the server out of the page', () {
      const html =
          '<p>Clips</p>'
          '<audio controls aria-label="Morning note" '
          'src="https://chat.example.test/api/v1/files/a1/content"></audio>'
          '<video controls width="640" height="360" title="Walkthrough">'
          '<source src="/api/v1/files/v1/content" type="video/mp4">'
          '</video>'
          '<p>End</p>';

      final media = _extract(html);

      check(media.items).deepEquals([
        WebEmbedMediaItem(
          kind: WebEmbedMediaKind.audio,
          sources: [
            Uri.parse('https://chat.example.test/api/v1/files/a1/content'),
          ],
          label: 'Morning note',
        ),
        WebEmbedMediaItem(
          kind: WebEmbedMediaKind.video,
          sources: [
            Uri.parse('https://chat.example.test/api/v1/files/v1/content'),
          ],
          label: 'Walkthrough',
        ),
      ]);
      check(media.html)
        ..not((it) => it.contains('<audio'))
        ..not((it) => it.contains('<video'))
        ..not((it) => it.contains('<source'))
        ..not((it) => it.contains('/api/v1/files/'))
        ..startsWith('<p>Clips</p><span data-conduit-media')
        ..endsWith('</span><p>End</p>');
      check(RegExp('data-conduit-media').allMatches(media.html).length)
          .equals(2);
      check(media.mediaOnly).isFalse();
    });

    test('keeps every source on the server, in page order', () {
      const html =
          '<audio controls>'
          '<source src="/api/v1/files/missing/content" type="audio/ogg">'
          '<source src="https://chat.example.test/api/v1/files/a1/content">'
          '</audio>';

      final media = _extract(html);

      check(media.items.single.sources.map((it) => '$it')).deepEquals([
        'https://chat.example.test/api/v1/files/missing/content',
        'https://chat.example.test/api/v1/files/a1/content',
      ]);
      check(media.html).not((it) => it.contains('<source'));
    });

    test('resolves relative addresses against the server', () {
      final cases = <(String, Uri, String)>[
        (
          '/api/v1/files/f1/content',
          _server,
          'https://chat.example.test/api/v1/files/f1/content',
        ),
        ('clips/note.mp3', _server, 'https://chat.example.test/clips/note.mp3'),
        (
          '//chat.example.test/a.mp3',
          _server,
          'https://chat.example.test/a.mp3',
        ),
        (
          'HTTPS://CHAT.example.test:443/b.mp3',
          _server,
          'https://chat.example.test/b.mp3',
        ),
        (' /c.mp3#t=10 ', _server, 'https://chat.example.test/c.mp3'),
        (
          '/api/v1/files/f2/content',
          Uri.parse('https://chat.example.test/owui/'),
          'https://chat.example.test/owui/api/v1/files/f2/content',
        ),
        (
          'note.mp3',
          Uri.parse('https://chat.example.test/owui'),
          'https://chat.example.test/owui/note.mp3',
        ),
      ];
      for (final (src, server, expected) in cases) {
        final media = _extract(
          '<audio controls src="$src"></audio>',
          server: server,
        );
        check(
          because: src,
          media.items.map((it) => it.url.toString()),
        ).deepEquals([expected]);
      }
    });

    test("resolves relative addresses against the page's base", () {
      check(
        _extract(
          '<base href="/api/v1/files/"><audio controls src="f1/content">'
          '</audio>',
        ).items.map((it) => it.url.toString()),
      ).deepEquals(['https://chat.example.test/api/v1/files/f1/content']);

      // A base anywhere else takes relative media there, so it stays, even
      // with the base after it: a page has one base address.
      for (final html in [
        '<base href="https://cdn.example.test/media/">'
            '<audio controls src="clip.mp3"></audio>',
        '<audio controls src="/api/v1/files/f1/content"></audio>'
            '<base href="https://cdn.example.test/">',
      ]) {
        final media = _extract(html);
        check(because: html, media.items).isEmpty();
        check(because: html, media.html).equals(html);
      }
      check(
        _extract(
          '<base href="https://cdn.example.test/">'
          '<audio controls src="https://chat.example.test/a.mp3"></audio>',
        ).items.map((it) => it.url.toString()),
      ).deepEquals(['https://chat.example.test/a.mp3']);
    });

    test('leaves media on any other origin in the page as it is', () {
      for (final html in [
        '<audio controls src="https://cdn.example.test/a.mp3"></audio>',
        '<audio controls src="http://chat.example.test/a.mp3"></audio>',
        '<audio controls src="https://chat.example.test:8443/a.mp3"></audio>',
        '<audio controls src="https://user:pw@chat.example.test/a.mp3"></audio>',
        '<audio controls src="\\\\cdn.example.test/a.mp3"></audio>',
        '<audio controls src="data:audio/wav;base64,UklGRg=="></audio>',
        '<audio controls src=""></audio>',
        // A src attribute wins over source children, as in a browser.
        '<video src="https://cdn.example.test/v.mp4">'
            '<source src="/api/v1/files/v1/content"></video>',
        // Every source must be on the server for the element to move.
        '<video><source src="https://cdn.example.test/v.webm">'
            '<source src="/api/v1/files/v1/content"></video>',
      ]) {
        final media = _extract(html);
        check(because: html, media.items).isEmpty();
        check(because: html, media.html).equals(html);
      }
    });

    test('ignores markup inside scripts, styles, comments and attributes', () {
      const html =
          '<script>const t = \'<audio src="/api/v1/files/s/content"></audio>\';'
          '</script>'
          '<style>/* <video src="/api/v1/files/s/content"> */</style>'
          '<!-- <audio controls src="/api/v1/files/c/content"></audio> -->'
          '<div data-template=\'<audio src="/api/v1/files/a/content">\'></div>'
          '<textarea><audio src="/api/v1/files/t/content"></audio></textarea>'
          '<template><audio controls src="/api/v1/files/p/content"></audio>'
          '</template>';

      final media = _extract(html);

      check(media.items).isEmpty();
      check(media.html).equals(html);
    });

    test('takes at most the cap and leaves the rest in the page', () {
      final html = [
        for (var i = 0; i < 12; i++)
          '<audio controls src="/api/v1/files/f$i/content"></audio>',
      ].join();

      final media = _extract(html, maxItems: 10);

      check(media.items.map((it) => it.url.pathSegments[3]))
          .deepEquals([for (var i = 0; i < 10; i++) 'f$i']);
      check(media.html)
        ..not((it) => it.contains('/api/v1/files/f9/'))
        ..contains('<audio controls src="/api/v1/files/f10/content"></audio>')
        ..contains('<audio controls src="/api/v1/files/f11/content"></audio>');
      check(media.mediaOnly).isFalse();
    });

    test('keeps the rest of the page as written', () {
      const html =
          '<p>a</p>\r\n<div>\r\n<audio controls src="/x.mp3">\r\n</audio>'
          '</div>\r\n<p title="b\r\nc">d</p>';

      final media = _extract(html);

      check(media.items).length.equals(1);
      check(media.html)
        ..startsWith('<p>a</p>\n<div>\n<span data-conduit-media')
        ..endsWith('</span></div>\n<p title="b\nc">d</p>');
    });

    test('takes elements wherever the parser puts them', () {
      for (final html in [
        // No end tag.
        '<body><audio controls src="/x.mp3"><source src="/y.mp3">',
        // Moved out of a table.
        '<table><audio controls src="/x.mp3"></audio><tr><td>a</td></tr>'
            '</table>',
        // HTML inside SVG.
        '<svg><foreignObject><audio controls src="/x.mp3"></audio>'
            '</foreignObject></svg>',
      ]) {
        final media = _extract(html);

        check(because: html, media.items.single.url.path).equals('/x.mp3');
        check(because: html, media.html)
          ..not((it) => it.contains('<audio'))
          ..not((it) => it.contains('<source'));
      }
    });

    test('reports a page that held nothing but the media', () {
      const voiceNote =
          '<!doctype html><html><head><style>audio{width:100%}</style></head>'
          '<body style="margin:0;background:transparent">'
          '<div class="card"><audio controls preload="metadata" '
          'src="/api/v1/files/n1/content"></audio></div>\n</body></html>';
      check(_extract(voiceNote).mediaOnly).isTrue();
      // Layout alone shows nothing.
      check(
        _extract(
          '<style>body{display:flex;justify-content:center}</style>'
          '<div style="align-content:center"><audio controls src="/n.mp3">'
          '</audio></div>',
        ).mediaOnly,
      ).isTrue();

      for (final html in [
        '<h3>Voice note</h3><audio controls src="/n.mp3"></audio>',
        '<audio controls src="/n.mp3"></audio><script>draw()</script>',
        '<audio controls src="/n.mp3"></audio><img src="/cover.png">',
        '<audio controls src="/n.mp3"></audio>'
            '<audio controls src="https://cdn.example.test/m.mp3"></audio>',
        // Styles can show text or an image of their own.
        '<style>.caption::before{content:"Transcript unavailable"}</style>'
            '<div class="caption"></div><audio controls src="/n.mp3"></audio>',
        '<div style="height:90px;background:URL(/cover.png)"></div>'
            '<audio controls src="/n.mp3"></audio>',
        '<link rel="Stylesheet" href="https://cdn.example.test/s.css">'
            '<audio controls src="/n.mp3"></audio>',
      ]) {
        check(because: html, _extract(html).mediaOnly).isFalse();
      }
    });

    test('changes nothing without a server', () {
      const html = '<audio controls src="/api/v1/files/f/content"></audio>';
      final media = extractWebEmbedServerMedia(html, server: null);
      check(media.items).isEmpty();
      check(media.html).equals(html);
    });
  });

  group('webEmbedMediaClient', () {
    late _Adapter adapter;
    late Dio client;

    setUp(() {
      adapter = _Adapter();
      client = webEmbedMediaClient(
        const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://chat.example.test',
        ),
        const {'Authorization': 'Bearer synthetic-token'},
      )..httpClientAdapter = adapter;
    });

    tearDown(() => client.close(force: true));

    test('sends the credential only to the server', () async {
      await check(
        client.getUri<void>(Uri.parse('https://cdn.example.test/a.mp3')),
      ).throws<DioException>();
      check(adapter.requests).isEmpty();

      adapter.reply = (_) => _media(200, 'audio/mpeg', 4);
      await openWebEmbedServerMedia(
        client,
        Uri.parse('https://chat.example.test/a.mp3'),
      );
      check(adapter.requests.single.headers['Authorization'])
          .equals('Bearer synthetic-token');
    });

    test('follows no redirect', () async {
      adapter.reply = (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://cdn.example.test/a.mp3'],
        },
      );
      await check(
        openWebEmbedServerMedia(
          client,
          Uri.parse('https://chat.example.test/a.mp3'),
        ),
      ).throws<DioException>();
      check(adapter.requests).length.equals(1);
    });

    test('refuses a reply that is not audio or video', () async {
      adapter.reply = (_) => ResponseBody.fromString(
        '<html>Sign in</html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
      await check(
        openWebEmbedServerMedia(
          client,
          Uri.parse('https://chat.example.test/a.mp3'),
        ),
      ).throws<WebEmbedMediaRefused>();
    });

    test('refuses a page before a download writes any of it', () async {
      adapter.reply = (_) => ResponseBody.fromString(
        '<html>Sign in</html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
      final dir = Directory.systemTemp.createTempSync('web_embed_media_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/clip.part';

      await check(client.download('https://chat.example.test/v.mp4', path))
          .throws<DioException>(
            (it) =>
                it.has((it) => it.error, 'error').isA<WebEmbedMediaRefused>(),
          );
      check(File(path).existsSync()).isFalse();
    });
  });

  group('openWebEmbedServerMedia', () {
    late _Adapter adapter;
    late Dio client;

    setUp(() {
      adapter = _Adapter();
      client = webEmbedMediaClient(
        const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://chat.example.test',
        ),
        const {},
      )..httpClientAdapter = adapter;
    });

    tearDown(() => client.close(force: true));

    test('streams the range the server sends', () async {
      adapter.reply = (_) => _media(
        206,
        'audio/wav',
        4,
        first: 10,
        extra: {
          'content-range': ['bytes 10-13/100'],
        },
      );

      final body = await openWebEmbedServerMedia(
        client,
        Uri.parse('https://chat.example.test/a.wav'),
        start: 10,
        end: 14,
      );

      check(adapter.requests.single.headers['Range']).equals('bytes=10-13');
      check(body.offset).equals(10);
      check(body.contentLength).equals(4);
      check(body.sourceLength).equals(100);
      check(body.contentType).equals('audio/wav');
      check(await _collect(body.stream)).deepEquals([10, 11, 12, 13]);
    });

    test('skips to the start when the server sends the whole file', () async {
      adapter.reply = (_) => _media(200, 'audio/mpeg', 8);

      final body = await openWebEmbedServerMedia(
        client,
        Uri.parse('https://chat.example.test/a.mp3'),
        start: 5,
      );

      check(body.offset).equals(5);
      check(body.contentLength).equals(3);
      check(body.sourceLength).equals(8);
      check(await _collect(body.stream)).deepEquals([5, 6, 7]);
    });

    test(
      'a whole file of unknown length is read from its first byte',
      () async {
        adapter.reply = (_) {
          final media = _media(200, 'audio/mpeg', 8);
          media.headers.remove(Headers.contentLengthHeader);
          return media;
        };

        final body = await openWebEmbedServerMedia(
          client,
          Uri.parse('https://chat.example.test/a.mp3'),
          start: 5,
        );

        check(adapter.requests.single.headers['Range']).equals('bytes=5-');
        check(body.offset).equals(0);
        check(body.contentLength).isNull();
        check(body.sourceLength).isNull();
        check(await _collect(body.stream)).deepEquals([0, 1, 2, 3, 4, 5, 6, 7]);
      },
    );
  });

  group('WebEmbedMediaReader', () {
    final missing = Uri.parse('https://chat.example.test/api/v1/files/m/c');
    final page = Uri.parse('https://chat.example.test/api/v1/files/p/c');
    final clip = Uri.parse('https://chat.example.test/api/v1/files/a/c');
    late _Adapter adapter;
    late Dio client;

    setUp(() {
      adapter = _Adapter();
      client = webEmbedMediaClient(
        const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://chat.example.test',
        ),
        const {},
      )..httpClientAdapter = adapter;
    });

    tearDown(() => client.close(force: true));

    test('reads the next source when one cannot be read', () async {
      adapter.reply = (options) {
        if (options.uri == missing) return ResponseBody.fromString('', 404);
        if (options.uri == page) {
          return ResponseBody.fromString(
            '<html>Sign in</html>',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html'],
            },
          );
        }
        return _media(200, 'audio/mpeg', 4);
      };
      final reader = WebEmbedMediaReader(client, [missing, page, clip]);

      final body = await reader.open(0, null);

      check(adapter.requests.map((it) => it.uri))
          .deepEquals([missing, page, clip]);
      check(await _collect(body.stream)).deepEquals([0, 1, 2, 3]);
      check(reader.index).equals(2);
      check(reader.nextIndex).isNull();
    });

    test('stays on a source once it has been read', () async {
      var failing = false;
      adapter.reply = (_) => failing
          ? ResponseBody.fromString('', 503)
          : _media(200, 'audio/mpeg', 4);
      final reader = WebEmbedMediaReader(client, [clip, page]);

      await _collect((await reader.open(0, null)).stream);
      failing = true;

      await check(reader.open(2, null)).throws<DioException>();
      check(adapter.requests.map((it) => it.uri)).deepEquals([clip, clip]);
      check(reader.nextIndex).equals(1);
      check(WebEmbedMediaReader(client, [clip, page], from: 1).index).equals(1);
    });

    test('overlapping reads agree on one source when the first fails late '
        'for one of them', () async {
      final firstFails = Completer<void>();
      final firstAnswers = Completer<void>();
      final secondAsked = Completer<void>();
      var firstRequests = 0;
      adapter.reply = (options) async {
        if (options.uri == missing) {
          if (firstRequests++ == 0) {
            await firstFails.future;
            return ResponseBody.fromString('', 503);
          }
          await firstAnswers.future;
          return _media(200, 'audio/mpeg', 4);
        }
        if (!secondAsked.isCompleted) secondAsked.complete();
        return _media(200, 'audio/mpeg', 4, first: 100);
      };
      final reader = WebEmbedMediaReader(client, [missing, clip]);

      final reads = [reader.open(0, null), reader.open(2, null)];
      // A read of the first source fails, and the reader moves on...
      firstFails.complete();
      await secondAsked.future;
      // ...before another read of the first source, if one is out, answers.
      firstAnswers.complete();

      final bodies = await Future.wait(reads);
      check(await _collect(bodies[0].stream)).deepEquals([100, 101, 102, 103]);
      check(await _collect(bodies[1].stream)).deepEquals([102, 103]);
      check(reader.index).equals(1);
      check(await _collect((await reader.open(1, null)).stream))
          .deepEquals([101, 102, 103]);
    });

    test('overlapping reads skip no source when the first fails for each '
        'at a different time', () async {
      final failures = [Completer<void>(), Completer<void>()];
      final secondAsked = Completer<void>();
      final secondAnswers = Completer<void>();
      var firstRequests = 0;
      adapter.reply = (options) async {
        if (options.uri == missing) {
          await failures[firstRequests++].future;
          return ResponseBody.fromString('', 503);
        }
        if (options.uri == page) {
          if (!secondAsked.isCompleted) secondAsked.complete();
          await secondAnswers.future;
          return _media(200, 'audio/mpeg', 4, first: 100);
        }
        return _media(200, 'audio/mpeg', 4, first: 200);
      };
      final reader = WebEmbedMediaReader(client, [missing, page, clip]);

      final reads = [reader.open(0, null), reader.open(0, null)];
      // One read of the first source fails, and the second is asked...
      failures[0].complete();
      await secondAsked.future;
      // ...then another read of the first, if one is out, fails before the
      // second answers.
      failures[1].complete();
      secondAnswers.complete();

      final bodies = await Future.wait(reads);
      for (final body in bodies) {
        check(await _collect(body.stream)).deepEquals([100, 101, 102, 103]);
      }
      check(reader.index).equals(1);
      check(adapter.requests.map((it) => it.uri))
          .not((it) => it.contains(clip));
    });
  });

  group('WebEmbedMediaLoad', () {
    final first = Uri.parse('https://chat.example.test/api/v1/files/a/c');
    final second = Uri.parse('https://chat.example.test/api/v1/files/b/c');
    final client = Dio();
    tearDownAll(() => client.close(force: true));

    test('a failure before the player is ready moves to the next source', () {
      final retries = <int?>[];
      final load = WebEmbedMediaLoad(
        WebEmbedMediaReader(client, [first, second]),
        onFailure: (retryFrom, _, _) => retries.add(retryFrom),
      );

      load.fail(StateError('format'), StackTrace.empty);

      check(retries).deepEquals([1]);
      check(load.isCurrent).isFalse();
    });

    test('a failure once the player is ready, or of the last source, '
        'shows the failure', () {
      final retries = <int?>[];
      final ready = WebEmbedMediaLoad(
        WebEmbedMediaReader(client, [first, second]),
        onFailure: (retryFrom, _, _) => retries.add(retryFrom),
      )..markReady();
      final last = WebEmbedMediaLoad(
        WebEmbedMediaReader(client, [first, second], from: 1),
        onFailure: (retryFrom, _, _) => retries.add(retryFrom),
      );

      ready.fail(StateError('playback'), StackTrace.empty);
      last.fail(StateError('format'), StackTrace.empty);

      check(retries).deepEquals([null, null]);
    });

    test('a load fails once, and not at all once cancelled', () {
      final retries = <int?>[];
      final failed = WebEmbedMediaLoad(
        WebEmbedMediaReader(client, [first, second]),
        onFailure: (retryFrom, _, _) => retries.add(retryFrom),
      );
      final cancelled = WebEmbedMediaLoad(
        WebEmbedMediaReader(client, [first, second]),
        onFailure: (retryFrom, _, _) => retries.add(retryFrom),
      );

      // A player reports a failed load both as an error event and by
      // throwing from the load.
      failed
        ..fail(StateError('event'), StackTrace.empty)
        ..fail(StateError('thrown'), StackTrace.empty);
      cancelled
        ..cancel()
        ..markReady()
        ..fail(StateError('late'), StackTrace.empty);

      check(retries).deepEquals([1]);
      check(cancelled.isCurrent).isFalse();
    });
  });
}

ResponseBody _media(
  int status,
  String type,
  int length, {
  int first = 0,
  Map<String, List<String>> extra = const {},
}) {
  final bytes = Uint8List.fromList([
    for (var i = 0; i < length; i++) first + i,
  ]);
  return ResponseBody(
    // Two chunks, so a skip has to cross a chunk boundary.
    Stream.fromIterable([
      bytes.sublist(0, length ~/ 2),
      bytes.sublist(length ~/ 2),
    ]),
    status,
    headers: {
      Headers.contentTypeHeader: [type],
      Headers.contentLengthHeader: ['$length'],
      ...extra,
    },
  );
}

Future<List<int>> _collect(Stream<List<int>> stream) async => [
  for (final chunk in await stream.toList()) ...chunk,
];

final class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  FutureOr<ResponseBody> Function(RequestOptions options) reply = (_) =>
      ResponseBody.fromString(jsonEncode({}), 404);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}
