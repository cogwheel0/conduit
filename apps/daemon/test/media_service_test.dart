@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// A synthetic one-pixel PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// A synthetic, minimal PDF header and body.
final Uint8List _pdf = Uint8List.fromList(
  utf8.encode('%PDF-1.4\n% synthetic test file\n%%EOF\n'),
);

const String _token = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';

void main() {
  late HttpServer site;
  late List<HttpHeaders> seen;
  late Map<String, Future<void> Function(HttpRequest)> pages;

  setUp(() async {
    seen = <HttpHeaders>[];
    pages = <String, Future<void> Function(HttpRequest)>{};
    site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    site.listen((request) async {
      seen.add(request.headers);
      final page = pages[request.uri.path];
      if (page == null) {
        request.response.statusCode = 404;
      } else {
        await page(request);
      }
      await request.response.close();
    });
  });

  tearDown(() => site.close(force: true));

  String at(String path) => 'http://127.0.0.1:${site.port}$path';

  // The site is on this Mac, which `/media` reaches only as the account's
  // own server: the fetching rules below hold for that origin and any
  // other; the address rule has tests of its own ('never this Mac').
  Future<Uri?> own() async => Uri.parse(at('/'));

  Future<void> serve(HttpRequest request, List<int> body, String type) async {
    request.response.headers.contentType = ContentType.parse(type);
    request.response.add(body);
  }

  test('a picture comes back with its type, and nothing about the user '
      'goes with the request', () async {
    pages['/tide.png'] = (r) => serve(r, _png, 'image/png');
    final media = MediaService(ownServer: own);
    addTearDown(media.close);
    final got = await media.fetch(at('/tide.png'), MediaKind.image);
    expect(got.bytes, _png);
    expect(got.contentType, 'image/png');
    final headers = seen.single;
    expect(headers.value(HttpHeaders.cookieHeader), isNull);
    expect(headers.value(HttpHeaders.refererHeader), isNull);
    expect(headers.value(HttpHeaders.authorizationHeader), isNull);
    expect(headers.value(HttpHeaders.userAgentHeader), 'Conduit');
    expect(headers.value(HttpHeaders.acceptHeader), startsWith('image/'));
  });

  test('a type the site gets wrong is read from the bytes; a page that is '
      'not a picture is refused', () async {
    pages['/mislabelled'] = (r) => serve(r, _png, 'application/octet-stream');
    pages['/page'] = (r) => serve(
      r,
      utf8.encode('<html><body>Not a picture</body></html>'),
      'text/html',
    );
    pages['/drawing.svg'] = (r) => serve(
      r,
      utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"></svg>'),
      'image/svg+xml',
    );
    final media = MediaService(ownServer: own);
    addTearDown(media.close);
    expect(
      (await media.fetch(at('/mislabelled'), MediaKind.image)).contentType,
      'image/png',
    );
    expect(
      (await media.fetch(at('/drawing.svg'), MediaKind.image)).contentType,
      'image/svg+xml',
    );
    await expectLater(
      media.fetch(at('/page'), MediaKind.image),
      throwsA(_failure(MediaFailure.wrongType)),
    );
    // A PDF must be a PDF.
    pages['/notes.pdf'] = (r) => serve(r, _pdf, 'application/pdf');
    expect(
      (await media.fetch(at('/notes.pdf'), MediaKind.pdf)).contentType,
      'application/pdf',
    );
    await expectLater(
      media.fetch(at('/mislabelled'), MediaKind.pdf),
      throwsA(_failure(MediaFailure.wrongType)),
    );
  });

  test('too large is refused, by the stated length or as it arrives', () async {
    final big = Uint8List(4096)..setAll(0, _png);
    pages['/stated.png'] = (r) => serve(r, big, 'image/png');
    pages['/streamed.png'] = (r) async {
      r.response.headers.contentType = ContentType.parse('image/png');
      r.response.bufferOutput = false;
      for (var i = 0; i < 8; i++) {
        r.response.add(big);
        await r.response.flush();
      }
    };
    final media = MediaService(ownServer: own, maxImageBytes: 2048);
    addTearDown(media.close);
    await expectLater(
      media.fetch(at('/stated.png'), MediaKind.image),
      throwsA(_failure(MediaFailure.tooLarge)),
    );
    await expectLater(
      media.fetch(at('/streamed.png'), MediaKind.image),
      throwsA(_failure(MediaFailure.tooLarge)),
    );
  });

  test('a slow site times out, and a failure is never tried again', () async {
    final hold = Completer<void>();
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    pages['/slow.png'] = (_) => hold.future;
    pages['/broken.png'] = (r) async => r.response.statusCode = 500;
    final media = MediaService(
      ownServer: own,
      timeout: const Duration(milliseconds: 300),
    );
    addTearDown(media.close);
    await expectLater(
      media.fetch(at('/slow.png'), MediaKind.image),
      throwsA(_failure(MediaFailure.timedOut)),
    );
    seen.clear();
    await expectLater(
      media.fetch(at('/broken.png'), MediaKind.image),
      throwsA(_failure(MediaFailure.failed)),
    );
    expect(seen, hasLength(1), reason: 'one request, no retry');
  });

  test('redirects are followed a few times, then refused', () async {
    pages['/moved.png'] = (r) async =>
        r.response.redirect(Uri.parse(at('/tide.png')));
    pages['/tide.png'] = (r) => serve(r, _png, 'image/png');
    for (var i = 0; i < 5; i++) {
      pages['/loop$i'] = (r) async =>
          r.response.redirect(Uri.parse(at('/loop${i + 1}')));
    }
    final media = MediaService(ownServer: own);
    addTearDown(media.close);
    expect((await media.fetch(at('/moved.png'), MediaKind.image)).bytes, _png);
    await expectLater(
      media.fetch(at('/loop0'), MediaKind.image),
      throwsA(_failure(MediaFailure.failed)),
    );
  });

  test('only plain http(s) addresses are fetched', () {
    for (final bad in <String>[
      'file:///etc/hosts',
      'data:image/png;base64,AAAA',
      'ftp://example.org/a.png',
      'https://name:secret@example.org/a.png',
      '/api/v1/files/abc/content',
      'not a url',
    ]) {
      expect(
        () => MediaService.parse(bad),
        throwsA(_failure(MediaFailure.invalidUrl)),
        reason: bad,
      );
    }
    expect(
      MediaService.parse('https://example.org/a.png#part').toString(),
      'https://example.org/a.png',
    );
  });

  test('the route needs the token and answers with the bytes or why not', () async {
    pages['/tide.png'] = (r) => serve(r, _png, 'image/png');
    final dir = await Directory.systemTemp.createTemp('conduitd_media');
    addTearDown(() => dir.delete(recursive: true));
    final server = DaemonServer(
      config: BootstrapConfig(
        sessionToken: _token,
        masterKey: base64.encode(List<int>.filled(32, 7)),
        userDataDir: dir.path,
      ),
      directories: DaemonDirectories.create(dir.path),
      daemonVersion: '0.0.0-test',
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    final port = await server.start();
    addTearDown(server.stop);
    final client = HttpClient();
    addTearDown(client.close);
    Future<HttpClientResponse> get(String path, {bool token = true}) async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      if (token) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      }
      return request.close();
    }

    final url = Uri.encodeQueryComponent(at('/tide.png'));
    final route = ConduitHttpRoutes.media;
    final refused = await get('$route/image?url=$url', token: false);
    await refused.drain<void>();
    expect(refused.statusCode, 401);
    expect(seen, isEmpty, reason: 'nothing is fetched without the token');

    // With no account, a site on this Mac is no one's own server.
    final local = await get('$route/image?url=$url');
    expect(local.statusCode, 403);
    final localBody =
        jsonDecode(await utf8.decodeStream(local)) as Map<String, dynamic>;
    expect(localBody['code'], 'media.refused');
    expect(seen, isEmpty, reason: 'a refused address is never connected');

    final lan = await _lanAddress();
    if (lan != null) {
      final lanSite = await HttpServer.bind(lan, 0);
      addTearDown(() => lanSite.close(force: true));
      lanSite.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(_png);
        await request.response.close();
      });
      final lanUrl = Uri.encodeQueryComponent(
        'http://${lan.address}:${lanSite.port}/tide.png',
      );
      final ok = await get('$route/image?url=$lanUrl');
      expect(ok.statusCode, 200);
      expect(ok.headers.contentType?.mimeType, 'image/png');
      expect(await ok.fold<List<int>>(<int>[], (a, b) => a..addAll(b)), _png);
      final missing = await get(
        '$route/image?url=${Uri.encodeQueryComponent('http://${lan.address}:1/gone.png')}',
      );
      expect(missing.statusCode, 502);
      final body =
          jsonDecode(await utf8.decodeStream(missing)) as Map<String, dynamic>;
      expect(body['code'], 'media.failed');
    }

    final wrongKind = await get('$route/video?url=$url');
    await wrongKind.drain<void>();
    expect(wrongKind.statusCode, 404);
  });
  group('never this Mac', () {
    test('loopback, unspecified, link-local and multicast addresses are '
        'refused before any connection', () async {
      final media = MediaService();
      addTearDown(media.close);
      for (final host in <String>[
        '127.0.0.1',
        '127.8.9.10',
        '[::1]',
        '0.0.0.0',
        '[::]',
        '169.254.169.254',
        '[fe80::1]',
        '224.0.0.251',
        '[ff02::1]',
        '[::ffff:127.0.0.1]',
        '[::ffff:169.254.169.254]',
        // Looked up as any name is: this Mac.
        'localhost',
      ]) {
        await expectLater(
          media.fetch('http://$host:${site.port}/tide.png', MediaKind.image),
          throwsA(_failure(MediaFailure.refused)),
          reason: host,
        );
      }
      expect(seen, isEmpty);
    });

    test('a name is checked by what it resolves to, where the connection is '
        'made (DNS rebinding)', () async {
      pages['/tide.png'] = (r) => serve(r, _png, 'image/png');
      final media = MediaService(
        lookup: (host) async => switch (host) {
          'pictures.example' => [InternetAddress.loopbackIPv4],
          // One refused answer refuses them all.
          'mixed.example' => [
            InternetAddress('10.20.30.40'),
            InternetAddress.loopbackIPv4,
          ],
          _ => <InternetAddress>[],
        },
      );
      addTearDown(media.close);
      for (final host in ['pictures.example', 'mixed.example']) {
        await expectLater(
          media.fetch('http://$host:${site.port}/tide.png', MediaKind.image),
          throwsA(_failure(MediaFailure.refused)),
          reason: host,
        );
      }
      expect(seen, isEmpty);
    });

    test('every redirect is checked again: the own server cannot send a '
        'fetch to another place on this Mac', () async {
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => other.close(force: true));
      var otherAsked = 0;
      other.listen((request) async {
        otherAsked++;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(_png);
        await request.response.close();
      });
      pages['/out.png'] = (r) async => r.response.redirect(
        Uri.parse('http://127.0.0.1:${other.port}/tide.png'),
      );
      pages['/rebind.png'] = (r) async => r.response.redirect(
        Uri.parse('http://rebind.example:${other.port}/tide.png'),
      );
      final media = MediaService(
        ownServer: own,
        lookup: (host) async => host == 'rebind.example'
            ? [InternetAddress.loopbackIPv4]
            : await InternetAddress.lookup(host),
      );
      addTearDown(media.close);
      for (final path in ['/out.png', '/rebind.png']) {
        await expectLater(
          media.fetch(at(path), MediaKind.image),
          throwsA(_failure(MediaFailure.refused)),
          reason: path,
        );
      }
      // The own server's origin is its port too.
      await expectLater(
        media.fetch('http://127.0.0.1:${other.port}/tide.png', MediaKind.image),
        throwsA(_failure(MediaFailure.refused)),
      );
      expect(otherAsked, 0);
      expect(seen, hasLength(2), reason: 'the own server, once per path');
    });

    test('a private LAN address is fetched', () async {
      final lan = await _lanAddress();
      if (lan == null) {
        markTestSkipped('no private LAN address on this machine');
        return;
      }
      final lanSite = await HttpServer.bind(lan, 0);
      addTearDown(() => lanSite.close(force: true));
      lanSite.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(_png);
        await request.response.close();
      });
      final media = MediaService();
      addTearDown(media.close);
      final got = await media.fetch(
        'http://${lan.address}:${lanSite.port}/tide.png',
        MediaKind.image,
      );
      expect(got.bytes, _png);
    });
  });
}

/// A private IPv4 address of this machine (10/8, 172.16/12, 192.168/16),
/// or null without one.
Future<InternetAddress?> _lanAddress() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      final b = address.rawAddress;
      final private =
          b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168);
      if (private) return address;
    }
  }
  return null;
}

Matcher _failure(MediaFailure failure) =>
    isA<MediaFetchException>().having((e) => e.failure, 'failure', failure);
