import 'dart:convert';
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
          url: Uri.parse('https://chat.example.test/api/v1/files/a1/content'),
          label: 'Morning note',
        ),
        WebEmbedMediaItem(
          kind: WebEmbedMediaKind.video,
          url: Uri.parse('https://chat.example.test/api/v1/files/v1/content'),
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

      for (final html in [
        '<h3>Voice note</h3><audio controls src="/n.mp3"></audio>',
        '<audio controls src="/n.mp3"></audio><script>draw()</script>',
        '<audio controls src="/n.mp3"></audio><img src="/cover.png">',
        '<audio controls src="/n.mp3"></audio>'
            '<audio controls src="https://cdn.example.test/m.mp3"></audio>',
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
  ResponseBody Function(RequestOptions options) reply = (_) =>
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
