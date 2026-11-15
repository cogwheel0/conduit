@TestOn('vm')
library;

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
      if (request.uri.path.endsWith('/moved')) {
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
    expect(elsewhereGot, isEmpty);
  });

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
}
