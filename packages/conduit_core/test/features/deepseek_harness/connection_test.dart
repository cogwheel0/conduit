import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:crypto/crypto.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

String encoded(List<int> value) => base64UrlEncode(value).replaceAll('=', '');

class HarnessFixture {
  HarnessFixture(this.server);
  final HttpServer server;
  final calls = <(String, Uri, String?)>[];
  int launchStatus = HttpStatus.seeOther;
  int indexStatus = HttpStatus.ok;
  String redirect = './';
  String Function(String)? modifyCookie;
  int version = 1;
  String? audience;
  String? signedCookie;

  Uri get root => Uri.parse('http://127.0.0.1:${server.port}/harness/');
  String get launchUrl =>
      root.replace(queryParameters: {'token': 'demo-launch'}).toString();

  Future<void> respond(HttpRequest request) async {
    final response = request.response;
    final cookie = request.headers.value('cookie');
    calls.add((request.method, request.uri, cookie));
    if (request.uri.hasQuery) {
      final authority = audience ?? root.authority;
      final name =
          'dsh-auth-${encoded(sha256.convert(utf8.encode(authority)).bytes)}';
      final now = DateTime.now().toUtc();
      final expiry = now.add(const Duration(days: 1));
      final payload = encoded(
        utf8.encode(
          jsonEncode({
            'version': version,
            'authority': authority,
            'issuedAt': now.millisecondsSinceEpoch,
            'expiresAt': expiry.millisecondsSinceEpoch,
          }),
        ),
      );
      final signature = encoded(
        Hmac(
          sha256,
          utf8.encode('synthetic-fixture'),
        ).convert(utf8.encode(payload)).bytes,
      );
      signedCookie = '$name=v$version.$payload.$signature';
      final header =
          '$signedCookie; HttpOnly; Path=/; SameSite=Strict; '
          'Max-Age=86400; Expires=${HttpDate.format(expiry)}';
      response.statusCode = launchStatus;
      response.headers
        ..set('Location', redirect)
        ..add('Set-Cookie', 'other=unrelated; Path=/')
        ..add('Set-Cookie', modifyCookie?.call(header) ?? header);
    } else {
      response.statusCode = cookie == signedCookie
          ? indexStatus
          : HttpStatus.unauthorized;
      response.headers.contentType = ContentType.html;
      if (indexStatus == HttpStatus.found) {
        response.headers.set('Location', '/elsewhere');
      }
    }
    await response.close();
  }
}

void main() {
  late HarnessFixture fixture;
  late InMemorySecureKeyValueStore storage;
  late ProviderContainer host;
  late DeepSeekHarnessConnections connections;
  ProviderContainer newHost() {
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Matcher fails(DeepSeekHarnessFailure reason) => throwsA(
    isA<DeepSeekHarnessException>().having(
      (error) => error.reason,
      'reason',
      reason,
    ),
  );

  setUp(() async {
    fixture = HarnessFixture(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen(fixture.respond);
    addTearDown(() => fixture.server.close(force: true));
    storage = InMemorySecureKeyValueStore();
    host = newHost();
    connections = host.read(deepSeekHarnessConnectionProvider.notifier);
  });

  test(
    'verifies the clean index and restores only the scoped browser grant',
    () async {
      final grant = await connections.connect(fixture.launchUrl);
      expect(fixture.calls, [
        ('GET', Uri.parse('/harness/?token=demo-launch'), null),
        ('HEAD', Uri.parse('/harness/'), fixture.signedCookie),
      ]);
      expect(grant.root, fixture.root);
      expect(grant.cookiePath, '/harness/');
      expect(grant.isExpired, isFalse);
      expect(
        grant.allowsNavigation(fixture.root.resolve('assets/main.js')),
        isTrue,
      );
      for (final url in [
        fixture.root.resolve('/harness-neighbor/'),
        fixture.root.resolve('%2Foutside'),
        fixture.root.resolve('../'),
        fixture.root.replace(scheme: 'https'),
        fixture.root.replace(host: 'example.invalid'),
        fixture.root.replace(port: fixture.root.port + 1),
        fixture.root.replace(userInfo: 'guest'),
        Uri.parse(fixture.launchUrl),
      ]) {
        expect(grant.allowsNavigation(url), isFalse);
      }
      final stored = (await storage.readAll()).values.single;
      expect(stored, isNot(contains('demo-launch')));
      expect(stored, isNot(contains('unrelated')));
      final secondHost = newHost();
      final restored = await secondHost.read(
        deepSeekHarnessConnectionProvider.future,
      );
      expect(restored?.root, grant.root);
      expect(restored?.cookieValue, grant.cookieValue);
      expect(restored?.expiresAt, grant.expiresAt);
      await secondHost
          .read(deepSeekHarnessConnectionProvider.notifier)
          .disconnect();
      expect(await storage.readAll(), isEmpty);
      expect(
        await secondHost.read(deepSeekHarnessConnectionProvider.future),
        isNull,
      );
    },
  );

  test('rejects invalid launch URLs before a network request', () async {
    for (final value in [
      fixture.root.toString(),
      '${fixture.root}?token=',
      '${fixture.launchUrl}&token=again',
      '${fixture.launchUrl}#fragment',
      '${fixture.launchUrl}&extra=x',
      fixture.launchUrl.replaceFirst('http:', 'file:'),
      fixture.launchUrl.replaceFirst('127.0.0.1', 'guest@127.0.0.1'),
    ]) {
      await expectLater(
        connections.connect(value),
        fails(DeepSeekHarnessFailure.invalidUrl),
      );
    }
    expect(fixture.calls, isEmpty);
    expect(await storage.readAll(), isEmpty);
  });

  test('never follows redirects on either request', () async {
    final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var received = 0;
    receiver.listen((request) async {
      received++;
      await request.response.close();
    });
    addTearDown(() => receiver.close(force: true));
    fixture.redirect = 'http://127.0.0.1:${receiver.port}/';
    await expectLater(
      connections.connect(fixture.launchUrl),
      fails(DeepSeekHarnessFailure.invalidResponse),
    );
    expect(received, 0);
    expect(fixture.calls.length, 1);
    fixture.redirect = '/sibling/';
    await expectLater(
      connections.connect(fixture.launchUrl),
      fails(DeepSeekHarnessFailure.invalidResponse),
    );
    expect(fixture.calls.length, 2);
    fixture.redirect = './';
    fixture.indexStatus = HttpStatus.found;
    await expectLater(
      connections.connect(fixture.launchUrl),
      fails(DeepSeekHarnessFailure.invalidResponse),
    );
    expect(fixture.calls.length, 4);
    expect(await storage.readAll(), isEmpty);
  });

  test(
    'rejects mismatched audience, peer grants and unsafe cookie attributes',
    () async {
      fixture.audience = 'unrelated.invalid';
      await expectLater(
        connections.connect(fixture.launchUrl),
        fails(DeepSeekHarnessFailure.invalidResponse),
      );
      fixture.audience = null;
      fixture.version = 2;
      await expectLater(
        connections.connect(fixture.launchUrl),
        fails(DeepSeekHarnessFailure.invalidResponse),
      );
      fixture.version = 1;
      for (final modify in <String Function(String)>[
        (cookie) => '$cookie; Domain=example.invalid',
        (cookie) => cookie.replaceFirst('HttpOnly;', ''),
        (cookie) => cookie.replaceFirst('SameSite=Strict', 'SameSite=None'),
        (cookie) => cookie.replaceFirst('Path=/', 'Path=/other/'),
        (cookie) => cookie.replaceFirst('86400', '0'),
        (cookie) => cookie.replaceFirst('v1.', 'v1.malformed.'),
      ]) {
        fixture.modifyCookie = modify;
        await expectLater(
          connections.connect(fixture.launchUrl),
          fails(DeepSeekHarnessFailure.invalidResponse),
        );
      }
      expect(fixture.calls.every((call) => call.$1 == 'GET'), isTrue);
      expect(await storage.readAll(), isEmpty);
    },
  );

  test(
    'preserves saved session across failed replacements, updates on success',
    () async {
      final first = await connections.connect(fixture.launchUrl);
      fixture.launchStatus = HttpStatus.forbidden;
      await expectLater(
        connections.connect(fixture.launchUrl),
        fails(DeepSeekHarnessFailure.untrustedHost),
      );
      fixture.launchStatus = HttpStatus.unauthorized;
      await expectLater(
        connections.connect(fixture.launchUrl),
        fails(DeepSeekHarnessFailure.unauthorized),
      );
      fixture.launchStatus = HttpStatus.seeOther;
      fixture.indexStatus = HttpStatus.unauthorized;
      await expectLater(
        connections.connect(fixture.launchUrl),
        fails(DeepSeekHarnessFailure.unauthorized),
      );
      expect(
        await host.read(deepSeekHarnessConnectionProvider.future),
        same(first),
      );
      expect(
        (await newHost().read(deepSeekHarnessConnectionProvider.future))
            ?.cookieValue,
        first.cookieValue,
      );
      fixture.indexStatus = HttpStatus.ok;
      final next = await connections.connect(fixture.launchUrl);
      expect(next.cookieValue, isNot(first.cookieValue));
      expect(
        await host.read(deepSeekHarnessConnectionProvider.future),
        same(next),
      );
    },
  );

  test(
    'workspace cleanup runs after verification and before replacing storage',
    () async {
      final first = await connections.connect(fixture.launchUrl);
      var called = false;
      Future<void> rejectReplacement() async {
        called = true;
        expect(
          (await newHost().read(deepSeekHarnessConnectionProvider.future))
              ?.cookieValue,
          first.cookieValue,
        );
        throw StateError('workspace cleanup failed');
      }

      fixture.indexStatus = HttpStatus.unauthorized;
      await expectLater(
        connections.connect(fixture.launchUrl, beforeSave: rejectReplacement),
        fails(DeepSeekHarnessFailure.unauthorized),
      );
      expect(called, isFalse);
      fixture.indexStatus = HttpStatus.ok;
      await expectLater(
        connections.connect(fixture.launchUrl, beforeSave: rejectReplacement),
        throwsStateError,
      );
      expect(called, isTrue);
      expect(
        await host.read(deepSeekHarnessConnectionProvider.future),
        same(first),
      );
    },
  );

  test(
    'a mounted workspace observes expiration without another navigation',
    () async {
      await connections.connect(fixture.launchUrl);
      final entry = (await storage.readAll()).entries.single;
      final json = jsonDecode(entry.value) as Map<String, dynamic>;
      final start = DateTime.now();
      const lifetime = Duration(minutes: 1);
      json['expiresAt'] = start.add(lifetime).millisecondsSinceEpoch;
      await storage.write(key: entry.key, value: jsonEncode(json));
      fakeAsync((time) {
        final restored = newHost();
        var expired = false;
        final sub = restored.listen(deepSeekHarnessConnectionProvider, (
          _,
          next,
        ) {
          if (!next.isLoading) expired = next.value?.isExpired == true;
        });
        addTearDown(sub.close);
        time.flushMicrotasks();
        expect(
          restored
              .read(deepSeekHarnessConnectionProvider)
              .requireValue
              ?.isExpired,
          isFalse,
        );
        expect(clock.now(), start);
        time.elapse(lifetime);
        time.flushMicrotasks();
        expect(expired, isTrue);
      }, initialTime: start);
    },
  );

  test('expired saved session remains removable and invalid stored scope is ignored', () async {
    await connections.connect(fixture.launchUrl);
    final entry = (await storage.readAll()).entries.single;
    final json = jsonDecode(entry.value) as Map<String, dynamic>;
    json['expiresAt'] = 0;
    await storage.write(key: entry.key, value: jsonEncode(json));
    final expired = await newHost().read(
      deepSeekHarnessConnectionProvider.future,
    );
    expect(expired?.isExpired, isTrue);
    json['root'] = 'https://another.invalid/';
    await storage.write(key: entry.key, value: jsonEncode(json));
    expect(
      await newHost().read(deepSeekHarnessConnectionProvider.future),
      isNull,
    );
    await connections.disconnect();
    expect(await storage.readAll(), isEmpty);
  });
}
