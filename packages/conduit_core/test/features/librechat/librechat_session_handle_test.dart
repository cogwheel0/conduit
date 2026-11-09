import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/librechat/models/librechat_cookies.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:test/test.dart';

/// A store whose writes can be made to fail.
final class _FlakyStore implements LibreChatSessionStore {
  LibreChatSession? session;
  bool failWrites = false;
  bool failClears = false;
  bool cleared = false;

  @override
  Future<LibreChatSession?> read() async => session;

  @override
  Future<void> write(LibreChatSession session) async {
    if (failWrites) throw StateError('keychain locked');
    this.session = session;
  }

  @override
  Future<void> clear() async {
    if (failClears) throw StateError('keychain locked');
    cleared = true;
    session = null;
  }
}

void main() {
  final now = DateTime.now().toUtc();
  const user = LibreChatUser(id: 'u1', name: 'Dev');
  LibreChatSession session(String token, List<String> setCookies) =>
      LibreChatSession(
        accessToken: token,
        user: user,
        cookies: const LibreChatCookies().apply(setCookies, now: now),
      );

  test('a renewal the store refuses still takes effect, and is saved on '
      'the next use', () async {
    final store = _FlakyStore()..failWrites = true;
    final handle = LibreChatSessionHandle(
      session: session('t1', ['refreshToken=r1']),
      store: store,
      renew: (current) async => session('t2', ['refreshToken=r2']),
    );
    addTearDown(handle.dispose);

    final renewed = await handle.renewAfterRefusal('t1');
    // The server rotated r1 away: keeping r2 is the only way to stay in.
    check(renewed.accessToken).equals('t2');
    check(handle.current!.cookies.value('refreshToken')).equals('r2');
    check(store.session).isNull();

    store.failWrites = false;
    await handle.fresh();
    check(store.session!.cookies.value('refreshToken')).equals('r2');
  });

  test('a renewal is stored before anything waiting on it runs', () async {
    final store = _FlakyStore();
    final release = Completer<void>();
    final handle = LibreChatSessionHandle(
      session: session('t1', ['refreshToken=r1']),
      store: store,
      renew: (current) async {
        await release.future;
        return session('t2', ['refreshToken=r2']);
      },
    );
    addTearDown(handle.dispose);
    final seen = <String?>[];
    handle.changes.listen(
      (change) => seen.add(store.session?.cookies.value('refreshToken')),
    );

    final renewal = handle.renewAfterRefusal('t1');
    release.complete();
    await renewal;
    // When the change was published, the store already held it.
    check(seen).deepEquals(['r2']);
  });

  test('cookies set while a renewal runs are kept', () async {
    final store = _FlakyStore();
    final release = Completer<void>();
    final handle = LibreChatSessionHandle(
      session: session('t1', ['refreshToken=r1']),
      store: store,
      renew: (current) async {
        await release.future;
        return current.copyWith(
          accessToken: 't2',
          cookies: current.cookies.apply(['refreshToken=r2'], now: now),
        );
      },
    );
    addTearDown(handle.dispose);

    final renewal = handle.renewAfterRefusal('t1');
    await handle.absorbCookies(['connect.sid=s1']);
    release.complete();
    await renewal;

    final cookies = handle.current!.cookies;
    check(cookies.value('refreshToken')).equals('r2');
    check(cookies.value('connect.sid')).equals('s1');
    check(store.session!.cookies.value('connect.sid')).equals('s1');
  });

  test('ending after dispose still forgets the stored session', () async {
    final store = _FlakyStore();
    final handle = LibreChatSessionHandle(
      session: session('t1', ['refreshToken=r1']),
      store: store,
      renew: (current) async => current,
    );
    await handle.dispose();
    await handle.end();
    check(store.cleared).isTrue();
    check(handle.isEnded).isTrue();
    // A late response after disposal neither throws nor revives it.
    await handle.absorbCookies(['refreshToken=late']);
    check(store.session).isNull();
  });

  test('a renewal asked of an ended session fails its future', () async {
    final handle = LibreChatSessionHandle(
      session: session('t1', ['refreshToken=r1']),
      store: _FlakyStore(),
      renew: (current) async => current,
    );
    addTearDown(handle.dispose);
    await handle.end();

    Object? caught;
    // Called outside any try: an ended session must not throw on the spot.
    final renewal = handle.renewAfterRefusal('t1');
    await renewal.catchError((Object error) {
      caught = error;
      return session('t0', const []);
    });
    check(caught).isA<LibreChatSessionExpiredException>();
  });

  test('an end the store refuses is retried by the next end', () async {
    final store = _FlakyStore()
      ..session = session('t1', ['refreshToken=r1'])
      ..failClears = true;
    final handle = LibreChatSessionHandle(
      session: session('t1', ['refreshToken=r1']),
      store: store,
      renew: (current) async => current,
    );
    addTearDown(handle.dispose);

    await check(handle.end()).throws<StateError>();
    check(handle.isEnded).isTrue();
    check(store.session).isNotNull();

    store.failClears = false;
    await handle.end();
    check(store.session).isNull();
  });

  test('a renewal that finds the session over says so, even when the store '
      'cannot forget it yet', () async {
    final store = _FlakyStore()
      ..session = session('t1', ['refreshToken=r1'])
      ..failClears = true;
    final handle = LibreChatSessionHandle(
      session: session('t1', ['refreshToken=r1']),
      store: store,
      renew: (current) async => throw const LibreChatSessionExpiredException(),
    );
    addTearDown(handle.dispose);

    await check(
      handle.renewAfterRefusal('t1'),
    ).throws<LibreChatSessionExpiredException>();
    check(handle.isEnded).isTrue();
  });

  group('merging cookie changes', () {
    test('keeps unrelated additions and applies sets and removals', () {
      final base = const LibreChatCookies().apply([
        'refreshToken=r1',
        'token_provider=librechat',
      ], now: now);
      final latest = base.apply(['connect.sid=s1'], now: now);
      final changed = base.apply([
        'refreshToken=r2',
        'token_provider=; Max-Age=0',
      ], now: now);

      final merged = latest.withChanges(base: base, changed: changed);
      check(merged.value('refreshToken')).equals('r2');
      check(merged.value('token_provider')).isNull();
      check(merged.value('connect.sid')).equals('s1');
      check(
        identical(latest.withChanges(base: base, changed: base), latest),
      ).isTrue();
    });
  });
}
