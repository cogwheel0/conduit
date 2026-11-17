@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

/// A port preview, against a stand-in for the terminal's port proxy: the
/// previewed page may reach its own port and nothing else, and the
/// credential the preview adds goes nowhere but there.
void main() {
  const prefix = '/api/v1/terminals/t1/proxy/3000';
  late HttpServer upstream;
  late HttpServer elsewhere;
  late PortPreview preview;
  late HttpClient browser;
  late String cookie;
  // Every path the port proxy was asked for.
  final asked = <String>[];
  // The Authorization header of every request that reached elsewhere.
  final elsewhereGot = <String?>[];

  setUp(() async {
    asked.clear();
    elsewhereGot.clear();
    elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    elsewhere.listen((request) async {
      elsewhereGot.add(request.headers.value('authorization'));
      await request.drain<void>();
      await request.response.close();
    });
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      asked.add(request.uri.path);
      await request.drain<void>();
      if (request.uri.path.endsWith('/inside')) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '$prefix/next?a=1');
      } else if (request.uri.path.endsWith('/moved')) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${elsewhere.port}/api/v1/auths/',
          );
      }
      await request.response.close();
    });
    preview = await PortPreview.start(
      upstream: Uri.parse('http://127.0.0.1:${upstream.port}$prefix/'),
      token: 'preview-secret',
      key: 'entry-key',
    );
    browser = HttpClient();
    final entry =
        await (await browser.getUrl(Uri.parse(preview.entryUrl))
              ..followRedirects = false)
            .close();
    await entry.drain<void>();
    cookie = entry.cookies.map((c) => '${c.name}=${c.value}').join('; ');
  });

  tearDown(() async {
    browser.close(force: true);
    await preview.close();
    await upstream.close(force: true);
    await elsewhere.close(force: true);
  });

  Future<HttpClientResponse> visit(
    String path, {
    String method = 'GET',
    String? origin,
  }) async {
    final request = await browser.openUrl(
      method,
      Uri.parse(preview.entryUrl).replace(path: '').resolve(path),
    );
    request
      ..followRedirects = false
      ..headers.set(HttpHeaders.cookieHeader, cookie);
    if (origin != null) request.headers.set('origin', origin);
    final response = await request.close();
    await response.drain<void>();
    return response;
  }

  test('a page on the port is asked for under the port', () async {
    expect((await visit('/index.html')).statusCode, HttpStatus.ok);
    expect(asked, <String>['$prefix/index.html']);
  });

  test('a redirect goes to the browser, not on with the credential', () async {
    final response = await visit('/moved');
    expect(response.statusCode, HttpStatus.found);
    expect(
      response.headers.value(HttpHeaders.locationHeader),
      'http://127.0.0.1:${elsewhere.port}/api/v1/auths/',
    );
    expect(elsewhereGot, isEmpty);
  });

  test('a redirect into the port stays on the preview', () async {
    final response = await visit('/inside');
    expect(response.statusCode, HttpStatus.found);
    expect(response.headers.value(HttpHeaders.locationHeader), '/next?a=1');
    expect(asked, <String>['$prefix/inside']);
  });

  test(
    'a first visit lands where it asks, and still not out of the port',
    () async {
      Future<String?> land(String to) async {
        final entry =
            await (await browser.getUrl(
                    Uri.parse(preview.entryUrl)
                        .replace(queryParameters: {'to': to}),
                  )
                  ..followRedirects = false)
                .close();
        await entry.drain<void>();
        return entry.headers.value(HttpHeaders.locationHeader);
      }

      expect(await land('/docs?page=2'), '/docs?page=2');
      expect(await land('//elsewhere.test/x'), '/');
      final climb = await land('/..%252F..%252Ffiles/read');
      expect((await visit(climb!)).statusCode, HttpStatus.badRequest);
      expect(asked, isEmpty);
    },
  );

  test('a path that would climb out of the port is refused', () async {
    // The proxy decodes `%2F` and then resolves the `..` it makes; a server
    // that decodes again reads `%252F` and deeper encodings the same way.
    for (final path in <String>[
      '/..%2F..%2Ffiles/read',
      '/..%252F..%252Ffiles/read',
      '/..%25252F..%25252Ffiles/read',
      '/..%252525252F..%252525252Ffiles/read',
      '/..%2f..%2Ffiles/read',
      '/%252e%252E/%252E%252e/files/read',
      '/..%5C..%5Cfiles/read',
      '/..%255c..%255Cfiles/read',
    ]) {
      expect(
        (await visit(path)).statusCode,
        HttpStatus.badRequest,
        reason: path,
      );
    }
    expect(asked, isEmpty);
  });

  // Open WebUI rewrites a page's root-relative links to its own proxy path.
  test('a path already under the port is not put under it twice', () async {
    await visit('$prefix/assets/app.js');
    expect(asked, <String>['$prefix/assets/app.js']);
  });

  test('another page on this computer cannot send through it', () async {
    final foreign = await visit(
      '/form',
      method: 'POST',
      origin: 'http://127.0.0.1:9',
    );
    expect(foreign.statusCode, HttpStatus.forbidden);
    final own = Uri.parse(preview.entryUrl).origin;
    expect(
      (await visit('/form', method: 'POST', origin: own)).statusCode,
      HttpStatus.ok,
    );
    expect(asked, <String>['$prefix/form']);
  });

  test('a path whose encoding never settles is refused', () {
    var path = '..%2Ffiles';
    for (var i = 0; i < 12; i++) {
      path = path.replaceAll('%', '%25');
    }
    expect(previewPathAllowed(Uri.parse('http://127.0.0.1/$path')), isFalse);
    expect(
      previewPathAllowed(Uri.parse('http://127.0.0.1/assets/app%20v2.js')),
      isTrue,
    );
  });

  group('the preview helpers', () {
    final upstream = Uri.parse(
      'https://chat.example.test/api/v1/terminals/box/proxy/5173/',
    );
    const boxPrefix = '/api/v1/terminals/box/proxy/5173';

    test('land where the first visit asks, on its own host only', () {
      expect(previewLanding(null), '/');
      expect(previewLanding('/docs?page=2'), '/docs?page=2');
      expect(previewLanding('https://elsewhere.test/'), '/');
      expect(previewLanding('//elsewhere.test/x'), '/');
      expect(previewLanding(r'/\elsewhere.test'), '/');
      expect(previewLanding('docs'), '/');
    });

    test('drop the proxy prefix Open WebUI wrote into a page', () {
      expect(previewUpstreamPath('/about', boxPrefix), '/about');
      expect(
        previewUpstreamPath('$boxPrefix/style.css', boxPrefix),
        '/style.css',
      );
      expect(previewUpstreamPath(boxPrefix, boxPrefix), '/');
      expect(
        previewUpstreamPath('${boxPrefix}0/x', boxPrefix),
        '${boxPrefix}0/x',
      );
    });

    test('keep a redirect into the port on the preview', () {
      expect(
        previewLocation('$boxPrefix/next?a=1#b', upstream, boxPrefix),
        '/next?a=1#b',
      );
      expect(previewLocation('/login', upstream, boxPrefix), '/login');
      expect(
        previewLocation(
          'https://chat.example.test$boxPrefix/',
          upstream,
          boxPrefix,
        ),
        '/',
      );
      expect(
        previewLocation('https://id.example.test/sign-in', upstream, boxPrefix),
        'https://id.example.test/sign-in',
      );
    });
  });

  group("a port preview's WebSocket", () {
    late HttpServer terminal;
    late PortPreview preview;
    final seen = <String, String?>{};
    // The port's end of the socket heard the close (its onDone ran).
    var upstreamClosed = Completer<void>();
    late StreamController<String> pushes;

    setUp(() async {
      seen.clear();
      upstreamClosed = Completer<void>();
      pushes = StreamController<String>.broadcast();
      // The terminal's proxy for port 5173, with a dev server behind it
      // whose live-reload socket echoes and pushes.
      terminal = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      terminal.listen((request) async {
        final path = request.uri.path;
        if (path == '/api/v1/terminals/box/proxy/5173/__moved') {
          // Out of the port, to the terminal's own API on its host.
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/api/v1/files/read');
          await request.response.close();
          return;
        }
        if (path != '/api/v1/terminals/box/proxy/5173/__hmr') {
          seen['other'] = path;
        }
        if (path == '/api/v1/terminals/box/proxy/5173/__hmr' &&
            WebSocketTransformer.isUpgradeRequest(request)) {
          seen['authorization'] = request.headers.value('authorization');
          seen['cookie'] = request.headers.value('cookie');
          seen['x-access'] = request.headers.value('x-access');
          seen['query'] = request.uri.query;
          final socket = await WebSocketTransformer.upgrade(
            request,
            protocolSelector: (offered) => 'vite-hmr',
          );
          final sub = pushes.stream.listen(socket.add);
          socket.listen(
            (message) => socket.add('echo:$message'),
            onDone: () {
              seen['closed'] = '${socket.closeCode}';
              unawaited(sub.cancel());
              if (!upstreamClosed.isCompleted) upstreamClosed.complete();
            },
          );
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      preview = await PortPreview.start(
        upstream: Uri.parse(
          'http://127.0.0.1:${terminal.port}/api/v1/terminals/box/proxy/5173/',
        ),
        token: 'terminal-token',
        key: 'visit-key',
        cookies: const {'gate': 'open'},
        headers: const {'x-access': 'harbour'},
      );
    });

    tearDown(() async {
      await preview.close();
      await terminal.close(force: true);
      await pushes.close();
    });

    /// The cookie the preview gives the first visit.
    Future<String> visit() async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(Uri.parse(preview.entryUrl));
      request.followRedirects = false;
      final response = await request.close();
      await response.drain<void>();
      final cookie = response.cookies.single;
      return '${cookie.name}=${cookie.value}';
    }

    String socketUrl(String path) => preview.entryUrl
        .replaceFirst(RegExp(r'^http'), 'ws')
        .replaceFirst(RegExp(r'/\.conduit-preview/.*$'), path);

    test('reaches the port with the credential, both ways', () async {
      final cookie = await visit();
      final socket = await WebSocket.connect(
        socketUrl('/__hmr?token=abc'),
        protocols: ['vite-hmr'],
        headers: {HttpHeaders.cookieHeader: cookie},
      );
      final received = StreamIterator(socket);
      expect(socket.protocol, 'vite-hmr');

      socket.add('ping');
      expect(await received.moveNext(), isTrue);
      expect(received.current, 'echo:ping');

      // The dev server says a file changed.
      pushes.add('{"type":"full-reload"}');
      expect(await received.moveNext(), isTrue);
      expect(received.current, '{"type":"full-reload"}');

      expect(seen['authorization'], 'Bearer terminal-token');
      expect(seen['cookie'], 'gate=open');
      expect(seen['x-access'], 'harbour');
      expect(seen['query'], 'token=abc');

      await socket.close(WebSocketStatus.normalClosure);
      await received.cancel();
      await upstreamClosed.future;
      expect(seen['closed'], '${WebSocketStatus.normalClosure}');
    });

    test('the prefix Open WebUI wrote into the page is dropped', () async {
      final cookie = await visit();
      final socket = await WebSocket.connect(
        socketUrl('/api/v1/terminals/box/proxy/5173/__hmr'),
        headers: {HttpHeaders.cookieHeader: cookie},
      );
      socket.add('hello');
      expect(await socket.first, 'echo:hello');
    });

    test('is refused without the visit\'s cookie', () async {
      await expectLater(
        WebSocket.connect(socketUrl('/__hmr')),
        throwsA(isA<WebSocketException>()),
      );
      expect(seen, isEmpty);
    });

    test('is refused, not followed, when the port redirects it', () async {
      final cookie = await visit();
      await expectLater(
        WebSocket.connect(
          socketUrl('/__moved'),
          headers: {HttpHeaders.cookieHeader: cookie},
        ),
        throwsA(isA<WebSocketException>()),
      );
      expect(seen['other'], isNull);
      expect(seen['authorization'], isNull);
    });

    test('is refused from another page on this computer', () async {
      final cookie = await visit();
      await expectLater(
        WebSocket.connect(
          socketUrl('/__hmr'),
          headers: {
            HttpHeaders.cookieHeader: cookie,
            'origin': 'http://127.0.0.1:9',
          },
        ),
        throwsA(isA<WebSocketException>()),
      );
      expect(seen, isEmpty);
      final own = Uri.parse(preview.entryUrl).origin;
      final socket = await WebSocket.connect(
        socketUrl('/__hmr'),
        headers: {HttpHeaders.cookieHeader: cookie, 'origin': own},
      );
      socket.add('mine');
      expect(await socket.first, 'echo:mine');
    });

    test('is refused when its path would climb out of the port', () async {
      final cookie = await visit();
      await expectLater(
        WebSocket.connect(
          socketUrl('/..%252F..%252Ffiles/read'),
          headers: {HttpHeaders.cookieHeader: cookie},
        ),
        throwsA(isA<WebSocketException>()),
      );
      expect(seen, isEmpty);
    });

    test('is refused when the port refuses it', () async {
      final cookie = await visit();
      await expectLater(
        WebSocket.connect(
          socketUrl('/nothing-here'),
          headers: {HttpHeaders.cookieHeader: cookie},
        ),
        throwsA(isA<WebSocketException>()),
      );
    });
  });
}
