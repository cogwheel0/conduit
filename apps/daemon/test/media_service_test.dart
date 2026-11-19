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
    final asked = Completer<void>();
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    pages['/slow.png'] = (_) {
      asked.complete();
      return hold.future;
    };
    pages['/broken.png'] = (r) async => r.response.statusCode = 500;
    final deadline = _Deadline();
    final media = MediaService(ownServer: own, deadline: deadline.start);
    addTearDown(media.close);
    final slow = media.fetch(at('/slow.png'), MediaKind.image);
    await asked.future;
    deadline.fire();
    await expectLater(slow, throwsA(_failure(MediaFailure.timedOut)));
    seen.clear();
    await expectLater(
      media.fetch(at('/broken.png'), MediaKind.image),
      throwsA(_failure(MediaFailure.failed)),
    );
    expect(seen, hasLength(1), reason: 'one request, no retry');
  });

  test(
    'the time limit covers the whole fetch: its connection and its body',
    () async {
      // A body that stops after its first bytes.
      final hold = Completer<void>();
      final stalled = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      pages['/stall.png'] = (r) async {
        r.response.headers.contentType = ContentType('image', 'png');
        r.response.add(_png.sublist(0, 8));
        await r.response.flush();
        stalled.complete();
        await hold.future;
      };
      var deadline = _Deadline();
      final lookups = Completer<List<InternetAddress>>();
      addTearDown(() {
        if (!lookups.isCompleted) lookups.complete(<InternetAddress>[]);
      });
      final media = MediaService(
        ownServer: own,
        deadline: (d, f) => deadline.start(d, f),
        // A name whose lookup never answers.
        lookup: (host) => lookups.future,
      );
      addTearDown(media.close);
      final body = media.fetch(at('/stall.png'), MediaKind.image);
      await stalled.future;
      // The headers and first bytes reach the fetch, which reads on.
      await pumpEventQueue(times: 50);
      deadline.fire();
      await expectLater(body, throwsA(_failure(MediaFailure.timedOut)));

      deadline = _Deadline();
      final connecting = media.fetch(
        'http://pictures.example:${site.port}/tide.png',
        MediaKind.image,
      );
      await pumpEventQueue();
      deadline.fire();
      await expectLater(connecting, throwsA(_failure(MediaFailure.timedOut)));
    },
  );

  test('a fetch that starts on the account\'s server never leaves it on a '
      'redirect', () async {
    // The server's own address is loaded without asking: a redirect from it
    // to another site would load that site without the user's say-so.
    pages['/away.png'] = (r) async => r.response.redirect(
      Uri.parse('http://pictures.example:${site.port}/tide.png'),
    );
    pages['/here.png'] = (r) async =>
        r.response.redirect(Uri.parse(at('/tide.png')));
    pages['/tide.png'] = (r) => serve(r, _png, 'image/png');
    final looked = <String>[];
    final media = MediaService(
      ownServer: own,
      lookup: (host) async {
        looked.add(host);
        return <InternetAddress>[];
      },
    );
    addTearDown(media.close);
    await expectLater(
      media.fetch(at('/away.png'), MediaKind.image),
      throwsA(_failure(MediaFailure.refused)),
    );
    expect(looked, isEmpty, reason: 'the other site is never asked');
    // On the same origin it is followed.
    expect((await media.fetch(at('/here.png'), MediaKind.image)).bytes, _png);
  });

  group('an answer it does not read is let go at once', () {
    // A site that sends its answer's head and then stalls the rest: the
    // fetch must neither wait on the rest nor keep the connection.
    late HttpServer stalling;
    late Map<String, String> heads;
    late Map<String, Completer<void>> released;
    late Completer<void> hold;

    setUp(() async {
      heads = <String, String>{};
      released = <String, Completer<void>>{};
      hold = Completer<void>();
      stalling = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      stalling.listen((request) async {
        final path = request.uri.path;
        final head = heads[path];
        if (head == null) {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(_png);
          await request.response.close();
          return;
        }
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.add(utf8.encode('$head\r\n\r\nThe first bytes of a body'));
        await socket.flush();
        final gone = released.putIfAbsent(path, Completer<void>.new);
        // The fetch letting go ends the connection; the site never would.
        socket.listen(
          (_) {},
          onDone: () {
            if (!gone.isCompleted) gone.complete();
          },
          onError: (Object _) {
            if (!gone.isCompleted) gone.complete();
          },
        );
        await hold.future;
        socket.destroy();
      });
    });

    tearDown(() async {
      if (!hold.isCompleted) hold.complete();
      await stalling.close(force: true);
    });

    String stalled(String path) => 'http://127.0.0.1:${stalling.port}$path';
    Future<Uri?> stallingIsOwn() async => Uri.parse(stalled('/'));

    MediaService service(_Deadline deadline) {
      final media = MediaService(
        ownServer: stallingIsOwn,
        deadline: deadline.start,
        maxImageBytes: 1024,
      );
      addTearDown(media.close);
      return media;
    }

    test('an error status', () async {
      heads['/gone.png'] =
          'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n'
          'Content-Length: 100000';
      final deadline = _Deadline();
      await expectLater(
        service(deadline).fetch(stalled('/gone.png'), MediaKind.image),
        throwsA(_failure(MediaFailure.failed)),
      );
      await released['/gone.png']!.future;
      expect(deadline.isActive, isFalse);
    });

    test('a redirect', () async {
      heads['/moved.png'] =
          'HTTP/1.1 302 Found\r\nLocation: /tide.png\r\n'
          'Content-Type: text/html\r\nContent-Length: 100000';
      final deadline = _Deadline();
      final fetched = await service(deadline)
          .fetch(stalled('/moved.png'), MediaKind.image);
      expect(fetched.bytes, _png);
      await released['/moved.png']!.future;
      expect(deadline.isActive, isFalse);
    });

    test('an answer larger than the limit', () async {
      heads['/huge.png'] =
          'HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n'
          'Content-Length: 100000';
      final deadline = _Deadline();
      await expectLater(
        service(deadline).fetch(stalled('/huge.png'), MediaKind.image),
        throwsA(_failure(MediaFailure.tooLarge)),
      );
      await released['/huge.png']!.future;
      expect(deadline.isActive, isFalse);
    });

    test(
      'and the time limit still ends a fetch waiting on a stalled head',
      () async {
        // A site that accepts the request and never answers at all.
        final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final gone = Completer<void>();
        final arrived = Completer<void>();
        silent.listen((socket) {
          socket.listen(
            (_) {
              if (!arrived.isCompleted) arrived.complete();
            },
            onDone: () {
              if (!gone.isCompleted) gone.complete();
            },
            onError: (Object _) {
              if (!gone.isCompleted) gone.complete();
            },
          );
        });
        addTearDown(silent.close);
        final deadline = _Deadline();
        final media = MediaService(
          ownServer: () async => Uri.parse('http://127.0.0.1:${silent.port}/'),
          deadline: deadline.start,
        );
        addTearDown(media.close);
        final waiting = media.fetch(
          'http://127.0.0.1:${silent.port}/tide.png',
          MediaKind.image,
        );
        await arrived.future;
        deadline.fire();
        await expectLater(waiting, throwsA(_failure(MediaFailure.timedOut)));
        await gone.future;
      },
    );
  });

  test('a redirect stays on the host the user allowed: another host is '
      'refused, the same host followed', () {
    final own = Uri.parse('https://owui.example.test:8443/');
    Uri u(String s) => Uri.parse(s);
    // A site the user allowed (by host).
    expect(
      MediaService.hopAllowed(
        u('https://pictures.example/a.png'),
        u('https://tracker.example/pixel.png'),
        own,
      ),
      isFalse,
    );
    expect(
      MediaService.hopAllowed(
        u('http://pictures.example/a.png'),
        u('https://pictures.example/b.png'),
        own,
      ),
      isTrue,
    );
    expect(
      MediaService.hopAllowed(
        u('https://pictures.example/a.png'),
        u('https://cdn.pictures.example/a.png'),
        own,
      ),
      isFalse,
    );
    // The account's server: its exact origin only.
    expect(
      MediaService.hopAllowed(
        u('https://owui.example.test:8443/a.png'),
        u('https://owui.example.test:9443/a.png'),
        own,
      ),
      isFalse,
    );
    expect(
      MediaService.hopAllowed(
        u('https://owui.example.test:8443/a.png'),
        u('https://owui.example.test:8443/b.png'),
        own,
      ),
      isTrue,
    );
  });

  test('an allowed site redirecting to another host is refused before that '
      'host is asked', () async {
    final lan = await _lanAddress();
    if (lan == null) {
      markTestSkipped('no private LAN address on this machine');
      return;
    }
    final lanSite = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    addTearDown(() => lanSite.close(force: true));
    lanSite.listen((r) async {
      r.response.redirect(
        Uri.parse('http://tracker.example:${lanSite.port}/pixel.png'),
      );
      await r.response.close();
    });
    final looked = <String>[];
    final media = MediaService(
      ownServer: own,
      lookup: (host) async {
        looked.add(host);
        return host == 'pictures.example' ? [lan] : <InternetAddress>[];
      },
    );
    addTearDown(media.close);
    await expectLater(
      media.fetch(
        'http://pictures.example:${lanSite.port}/tide.png',
        MediaKind.image,
      ),
      throwsA(_failure(MediaFailure.refused)),
    );
    expect(looked, ['pictures.example']);
  });

  test('a lookup that answers after the time limit connects nothing', () async {
    final accepted = <Socket>[];
    final listening = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    listening.listen(accepted.add);
    addTearDown(() async {
      for (final s in accepted) {
        s.destroy();
      }
      await listening.close();
    });
    final answer = Completer<List<InternetAddress>>();
    addTearDown(() {
      if (!answer.isCompleted) answer.complete(<InternetAddress>[]);
    });
    final asked = Completer<void>();
    final deadline = _Deadline();
    final ownAt = Uri.parse('http://own.example:${listening.port}/');
    final media = MediaService(
      ownServer: () async => ownAt,
      deadline: deadline.start,
      lookup: (host) {
        if (!asked.isCompleted) asked.complete();
        return answer.future;
      },
    );
    addTearDown(media.close);
    final fetching = media.fetch(
      'http://own.example:${listening.port}/tide.png',
      MediaKind.image,
    );
    await asked.future;
    deadline.fire();
    await expectLater(fetching, throwsA(_failure(MediaFailure.timedOut)));
    // The name resolves now, after the limit: nothing may connect.
    answer.complete([InternetAddress.loopbackIPv4]);
    await pumpEventQueue(times: 50);
    expect(accepted, isEmpty);
  });

  test(
    'every fetch opens its own connection: none is kept for another',
    () async {
      pages['/tide.png'] = (r) => serve(r, _png, 'image/png');
      final ports = <int?>[];
      final watched = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => watched.close(force: true));
      watched.listen((r) async {
        ports.add(r.connectionInfo?.remotePort);
        r.response.headers.contentType = ContentType('image', 'png');
        r.response.add(_png);
        await r.response.close();
      });
      final media = MediaService(
        ownServer: () async => Uri.parse('http://127.0.0.1:${watched.port}/'),
      );
      addTearDown(media.close);
      for (var i = 0; i < 2; i++) {
        await media.fetch(
          'http://127.0.0.1:${watched.port}/tide.png',
          MediaKind.image,
        );
      }
      expect(ports, hasLength(2));
      expect(
        ports.toSet(),
        hasLength(2),
        reason: 'a pooled connection was reused',
      );
    },
  );

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

/// The fetch's time limit, fired by the test instead of a clock.
final class _Deadline implements Timer {
  void Function()? _expire;
  bool _active = false;

  Timer start(Duration _, void Function() expire) {
    _expire = expire;
    _active = true;
    return this;
  }

  void fire() {
    final expire = _expire;
    if (_active && expire != null) {
      _active = false;
      expire();
    }
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
