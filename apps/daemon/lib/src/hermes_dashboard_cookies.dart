import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_cookie_registry.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_http_session.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';
import 'package:conduit_core/features/hermes/services/hermes_http_transport.dart';
import 'package:conduit_core/ports/cookie_jar_port.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';

/// The secure store key the dashboard sessions' cookies are kept under.
const String kHermesDashboardCookiesKey = 'hermes.dashboardCookies';

/// The base names (without a `__Host-`/`__Secure-` prefix or a gateway's
/// `_<16 hex>` suffix) of the cookies that hold a dashboard session.
const Set<String> _sessionCookieNames = {
  'hermes_session_at',
  'hermes_session_rt',
};

bool _isSessionCookie(String name) => _sessionCookieNames.contains(
  name
      .replaceFirst(RegExp(r'^__(?:Host|Secure)-'), '')
      .replaceFirst(RegExp(r'_[0-9a-f]{16}$'), ''),
);

/// The daemon's cookie store: what a WebView's is on a phone, for the one
/// thing the daemon needs one for, a Desktop Gateway's dashboard sign-in.
///
/// The window runs the sign-in in a browser window of its own, with a
/// store of its own that goes with the window, and hands the dashboard's
/// cookies over ([adopt]). From then on the daemon is the browser: the
/// dashboard bridge ([bridge]) sends them with each dashboard request and
/// keeps what Hermes rotates, a sign-out ([signOut]) asks Hermes to end the
/// session, and the core's [clearForOrigin] deletes what the sign-in
/// recorded ([HermesDashboardCookieRegistry]), as the phone's WebView glue
/// does. The cookies are secrets: they live in the secure store.
///
/// A sign-in's cookies enter the jar at one commit point ([_commit]), taken
/// in turn with every clear: only while no clear started after the sign-in
/// did and its caller still wants them (the connection it was made under is
/// still in use), and an answer of signed in means they were saved.
///
/// A purge is real or says it is not: [clearForOrigin] and [clearAll] answer
/// true only once the secure store no longer holds the cookies. One whose
/// write failed leaves them out of the jar and is written again by the next
/// purge or [completePendingClear]. [clearAll], the full purge the core asks
/// for at an Open WebUI sign-out, empties the jar, as the phone's shared
/// WebView store is emptied.
final class DaemonHermesDashboardCookies implements CookieJarPort {
  DaemonHermesDashboardCookies._(this._store, this._jar);

  /// Reads the kept cookies from [store].
  static Future<DaemonHermesDashboardCookies> open(
    SecureKeyValueStore store,
  ) async {
    HermesDashboardCookieJar jar;
    try {
      final source = await store.read(key: kHermesDashboardCookiesKey);
      jar = source == null
          ? HermesDashboardCookieJar()
          : HermesDashboardCookieJar.fromJson(jsonDecode(source));
    } on Object {
      jar = HermesDashboardCookieJar();
    }
    return DaemonHermesDashboardCookies._(store, jar);
  }

  final SecureKeyValueStore _store;
  final HermesDashboardCookieJar _jar;
  Future<void> _saving = Future<void>.value();

  /// The tail of the commits and clears, run one at a time.
  Future<void> _turn = Future<void>.value();

  /// Bumped by [clearAll]: a write begun under an older one keeps nothing.
  int _epoch = 0;

  /// Per origin key, bumped by each [clearForOrigin] of it as it starts
  /// (before its own write, which may fail): a write begun before keeps
  /// nothing.
  final Map<String, int> _purges = {};

  static String _originKey(String origin) =>
      hermesDashboardCookieOriginKey(origin) ?? origin;

  /// What a write to [origin]'s cookies starts under, taken when its
  /// request starts.
  ({int epoch, int purges}) _ticket(String origin) =>
      (epoch: _epoch, purges: _purges[_originKey(origin)] ?? 0);

  /// Whether no purge of [origin], and no full purge, started since
  /// [ticket] was taken.
  bool _unpurged(String origin, ({int epoch, int purges}) ticket) =>
      ticket == _ticket(origin);

  /// Purges asked whose emptying has not run yet: per origin key, and
  /// full ones. Set as a purge is asked, cleared once it has emptied the
  /// jar (in its turn, before its write).
  final Map<String, int> _pendingPurges = {};
  int _pendingFullPurges = 0;

  /// Whether a purge covering [origin] is asked and has not emptied the
  /// jar yet: the jar still holds what it will remove.
  bool _purgePending(String origin) =>
      _pendingFullPurges > 0 || (_pendingPurges[_originKey(origin)] ?? 0) > 0;

  /// The intake of one dashboard request to [root], taken as the request
  /// reads its cookies, and with its ticket taken at that same moment. A
  /// request made while a purge of its origin waits to empty the jar reads
  /// nothing: it is refused (it would read the cookies the purge removes
  /// under a ticket the purge already moved past). The intake keeps the
  /// answer's cookies only if no purge started since, in turn with the
  /// commits and clears.
  HermesDashboardCookieIntake _intake(Uri root) {
    final origin = root.toString();
    if (_purgePending(origin)) {
      throw StateError('The dashboard sign-in is being cleared.');
    }
    final ticket = _ticket(origin);
    return (url, setCookies) => _inTurn(() async {
      if (!_unpurged(origin, ticket)) return;
      if (_jar.absorb(url, setCookies)) await _saveRotated();
    });
  }

  /// The last write failed: the secure store may hold what the jar no
  /// longer does, so the next purge writes even with nothing left to remove.
  bool _dirty = false;

  /// The cookies, for tests and diagnostics.
  List<HermesDashboardCookie> get cookies => _jar.cookies;

  /// Writes the jar after the writes before it. A write that fails fails
  /// its caller (and marks the store [_dirty]); the next write still runs.
  Future<void> _save() {
    final value = _jar.isEmpty ? null : jsonEncode(_jar.toJson());
    final write = _saving
        .then(
          (_) => _store.write(key: kHermesDashboardCookiesKey, value: value),
        )
        .then(
          (_) => _dirty = false,
          onError: (Object error, StackTrace stack) {
            _dirty = true;
            Error.throwWithStackTrace(error, stack);
          },
        );
    _saving = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  /// [_save] for the dashboard bridge's rotations: a write that fails
  /// leaves the request alone (the next rotation writes again).
  Future<void> _saveRotated() => _save().catchError((Object _) {});

  /// Runs [body] after every commit and clear before it.
  Future<T> _inTurn<T>(Future<T> Function() body) {
    final run = _turn.then((_) => body());
    _turn = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// A purge's write: needed when [removed] changed the jar or an earlier
  /// write failed. True once the secure store holds what the jar does.
  Future<bool> _purged(bool removed) async {
    if (!removed && !_dirty) return true;
    try {
      await _save();
      return true;
    } on Object {
      return false;
    }
  }

  static String? _host(String origin) {
    final host = Uri.tryParse(origin)?.host;
    return host == null || host.isEmpty ? null : host;
  }

  /// The commit point: takes [cookies], a sign-in window's for [root]'s
  /// host, while sign-in [generation] is still [root]'s latest, no purge
  /// started since [ticket], and [wanted] still holds, checked in
  /// turn right before the jar changes. Those of its host are kept, and
  /// recorded as this sign-in's for [root] (the window's store was fresh,
  /// so every one of them is), as the phone's registers its sign-in. True
  /// when a session cookie was among them; false, with nothing taken, once
  /// superseded or unwanted. A save that fails puts the jar back and is
  /// thrown.
  Future<bool> _commit(
    Uri root,
    Iterable<HermesDashboardCookie> cookies, {
    required int generation,
    required ({int epoch, int purges}) ticket,
    bool Function()? wanted,
  }) {
    final origin = root.toString();
    return _inTurn(() async {
      if (!_unpurged(origin, ticket) ||
          !HermesDashboardCookieRegistry.isCurrent(origin, generation) ||
          !(wanted?.call() ?? true)) {
        return false;
      }
      final host = root.host;
      final taken = [
        for (final cookie in cookies)
          if (hermesDashboardCookieDomainMatches(
            cookie.domain,
            host,
            hostOnly: cookie.hostOnly,
          ))
            cookie,
      ];
      final replaced = {
        for (final cookie in _jar.cookies) cookie.identity: cookie,
      };
      for (final cookie in taken) {
        _jar.put(cookie);
      }
      try {
        await HermesDashboardCookieRegistry.record(
          origin,
          identities: hermesDashboardCookieIdentityDelta(
            current: {for (final cookie in taken) cookie.identity},
            baseline: const {},
            retainedNames: kHermesDashboardRetainedCookieNames,
            recorded: HermesDashboardCookieRegistry.identitiesFor(origin),
          ),
          retainedNames: kHermesDashboardRetainedCookieNames,
        );
        await _save();
      } on Object {
        final identities = {for (final cookie in taken) cookie.identity};
        _jar.removeAll(identities);
        for (final identity in identities) {
          final before = replaced[identity];
          if (before != null) _jar.put(before);
        }
        rethrow;
      }
      return taken.any((cookie) => _isSessionCookie(cookie.name));
    });
  }

  /// Whether a dashboard session this daemon recorded for [baseUrl]'s
  /// dashboard is still held.
  bool hasSession(String baseUrl) {
    final root = hermesDashboardRoot(baseUrl);
    final recorded = HermesDashboardCookieRegistry.identitiesFor(
      root.toString(),
    );
    if (recorded.isEmpty) return false;
    final held = _jar.identitiesFor(root.host);
    return _jar.cookies.any(
      (cookie) =>
          _isSessionCookie(cookie.name) &&
          recorded.contains(cookie.identity) &&
          held.contains(cookie.identity),
    );
  }

  /// The dashboard bridge for [root] ([HermesDashboardBridgeFactory]), on
  /// [httpClient] (the connection's certificate trust).
  HermesDashboardBridge bridge({
    required Uri root,
    required Map<String, String> accessHeaders,
    HermesDashboardHttpClientFactory? httpClient,
  }) => HermesDashboardHttpSession(
    root: root,
    accessHeaders: accessHeaders,
    jar: _jar,
    beginExchange: () => _intake(root),
    httpClient: httpClient,
  );

  /// Signs [root]'s dashboard session out on the server
  /// ([HermesDashboardSignOut]).
  Future<bool> signOut({
    required Uri root,
    required Map<String, String> accessHeaders,
    HermesDashboardHttpClientFactory? httpClient,
  }) => hermesDashboardHttpSignOut(
    root: root,
    accessHeaders: accessHeaders,
    jar: _jar,
    beginExchange: () => _intake(root),
    httpClient: httpClient,
  );

  /// Takes [cookies], which a sign-in window's page on [root]'s dashboard
  /// had, when the dashboard says they are a signed-in session
  /// ([hermesDashboardAuthCheckUrl] answers 2xx only then): checked on a
  /// jar of their own first, so cookies that are not a session never
  /// replace a session held. True when they were taken ([_commit]): not
  /// once a clear of [root] started after this sign-in did, or once
  /// [wanted] (the caller's own check, made in the commit's turn) fails.
  Future<bool> adopt(
    Uri root,
    Iterable<HermesDashboardCookie> cookies, {
    required Map<String, String> accessHeaders,
    HermesDashboardHttpClientFactory? httpClient,
    bool Function()? wanted,
  }) async {
    // Begun before the check goes out: a clear meanwhile supersedes it.
    final generation = HermesDashboardCookieRegistry.begin(root.toString());
    final ticket = _ticket(root.toString());
    final host = root.host;
    final own = HermesDashboardCookieJar([
      for (final cookie in cookies)
        if (hermesDashboardCookieDomainMatches(
          cookie.domain,
          host,
          hostOnly: cookie.hostOnly,
        ))
          cookie,
    ]);
    if (!own.cookies.any((cookie) => _isSessionCookie(cookie.name))) {
      return false;
    }
    final session = HermesDashboardHttpSession(
      root: root,
      accessHeaders: accessHeaders,
      jar: own,
      httpClient: httpClient,
    );
    try {
      final answer = await session.request(
        'GET',
        hermesDashboardAuthCheckUrl(root),
      );
      if (answer.status < 200 || answer.status >= 300) return false;
    } on Object {
      return false;
    } finally {
      await session.close();
    }
    // The check's answer may have rotated the session: its cookies are kept.
    return _commit(
      root,
      own.cookies,
      generation: generation,
      ticket: ticket,
      wanted: wanted,
    );
  }

  // CookieJarPort

  @override
  bool get isSupported => true;

  @override
  Future<Set<String>> identitiesFor(String origin) async {
    final host = _host(origin);
    return host == null ? const {} : _jar.identitiesFor(host);
  }

  @override
  Future<bool> clearForOrigin(String origin) {
    // Superseded now, before its turn: a sign-in waiting for one keeps
    // nothing.
    if (!HermesDashboardCookieRegistry.invalidate(origin)) {
      return Future<bool>.value(true);
    }
    final key = _originKey(origin);
    _purges[key] = (_purges[key] ?? 0) + 1;
    _pendingPurges[key] = (_pendingPurges[key] ?? 0) + 1;
    return _inTurn(() async {
      final bool removed;
      try {
        removed = _jar.removeAll(
          HermesDashboardCookieRegistry.identitiesFor(origin),
        );
      } finally {
        final left = (_pendingPurges[key] ?? 1) - 1;
        if (left > 0) {
          _pendingPurges[key] = left;
        } else {
          _pendingPurges.remove(key);
        }
      }
      // Gone from the jar but still in the secure store: not cleared yet,
      // and the record stays for the purge that writes it.
      if (!await _purged(removed)) return false;
      await HermesDashboardCookieRegistry.forget(origin);
      return true;
    });
  }

  /// Every cookie: the jar holds only dashboard sessions.
  @override
  Future<bool> clearCookies() => clearAll();

  @override
  Future<bool> clearWebsiteData() async => true;

  /// Empties the jar, superseding every sign-in still being checked.
  @override
  Future<bool> clearAll() {
    _epoch++;
    _pendingFullPurges++;
    return _inTurn(() {
      final bool removed;
      try {
        removed = _jar.removeAll({for (final c in _jar.cookies) c.identity});
      } finally {
        _pendingFullPurges--;
      }
      return _purged(removed);
    });
  }

  /// Writes a purge whose write failed before.
  @override
  Future<bool> completePendingClear() => _inTurn(() => _purged(false));
}

/// The HTTP client a dashboard request for [root] goes out on: [config]'s
/// certificate trust when it is that dashboard's connection.
HermesDashboardHttpClientFactory? hermesDashboardHttpClientFor(
  Uri root,
  HermesConfig config,
) {
  if (config.baseUrl.isEmpty ||
      !hermesDashboardIsExactOrigin(
        hermesDashboardRoot(config.baseUrl),
        root,
      )) {
    return null;
  }
  if (!config.allowSelfSignedCertificates) return null;
  return () => hermesTlsHttpClient(config) ?? HttpClient();
}
