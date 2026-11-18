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
/// session, and the core's [clearForOrigin] deletes them. The cookies are
/// secrets: they live in the secure store.
///
/// Each dashboard origin (`scheme://host:port`,
/// [hermesDashboardCookieOriginKey]) has a jar of its own, in memory and in
/// the store: a dashboard's requests, the cookies its answers set and its
/// sign-in read and write that jar only, so a cookie is sent only to the
/// origin that set it (cookies ignore ports; two gateways on one host keep
/// apart) and a clear of an origin deletes its jar whole, every cookie in
/// it, with nothing to record and nothing to miss.
///
/// A sign-in's cookies enter the jar at one commit point ([_commit]), taken
/// in turn with every clear: only while no clear started after the sign-in
/// did and its caller still wants them (the connection it was made under is
/// still in use), and an answer of signed in means they were saved.
///
/// A purge is real or says it is not: [clearForOrigin] and [clearAll] answer
/// true only once the secure store no longer holds the cookies. One whose
/// write failed leaves them out of the jar, and the store is written again
/// before anything else reads or writes it (by the next write, purge or
/// [completePendingClear]). [clearAll], the full purge the core asks for at
/// an Open WebUI sign-out, empties every jar, as the phone's shared WebView
/// store is emptied.
///
/// A store that could not be read at [open] is unread: what it holds is not
/// known, so nothing is written over it until it is read. Each write tries
/// to read it first; while it still cannot be, a sign-in is refused, a
/// rotation is kept in memory only, and a clear of one origin answers false
/// (the cookies leave the jar, and the store keeps its own until a later
/// read lets the purge be written). [clearAll] writes the empty store.
///
/// Cookies kept in the earlier single-jar form are dropped once, as the
/// store is opened, and the store is written in this form: a dashboard
/// signed in to before then signs in again.
final class DaemonHermesDashboardCookies implements CookieJarPort {
  DaemonHermesDashboardCookies._(
    this._store,
    this._jars, {
    bool unread = false,
    bool dirty = false,
  }) : _unread = unread,
       _dirty = dirty;

  /// Reads the kept cookies from [store]. A store that cannot be read
  /// starts every jar empty and [_unread]; one in the earlier single-jar
  /// form is emptied (written at once, else [_dirty]).
  static Future<DaemonHermesDashboardCookies> open(
    SecureKeyValueStore store,
  ) async {
    final String? source;
    try {
      source = await store.read(key: kHermesDashboardCookiesKey);
    } on Object {
      return DaemonHermesDashboardCookies._(store, {}, unread: true);
    }
    final (jars, legacy) = _decode(source);
    if (!legacy) return DaemonHermesDashboardCookies._(store, jars);
    try {
      await store.write(key: kHermesDashboardCookiesKey, value: null);
      return DaemonHermesDashboardCookies._(store, jars);
    } on Object {
      return DaemonHermesDashboardCookies._(store, jars, dirty: true);
    }
  }

  /// The jars kept in [source], per origin key, and whether it was in the
  /// earlier single-jar form (a list), whose cookies are dropped.
  static (Map<String, HermesDashboardCookieJar>, bool) _decode(String? source) {
    if (source == null) return ({}, false);
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return ({}, true);
    }
    if (decoded is! Map) return ({}, true);
    return (
      {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (key is String) key: HermesDashboardCookieJar.fromJson(value),
      },
      false,
    );
  }

  final SecureKeyValueStore _store;

  /// Per origin key. A jar, once made, stays (emptied by a clear): the
  /// dashboard sessions made on it keep reading the one the store keeps.
  final Map<String, HermesDashboardCookieJar> _jars;

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

  /// [origin]'s jar, made empty the first time.
  HermesDashboardCookieJar _jarFor(String origin) =>
      _jars.putIfAbsent(_originKey(origin), HermesDashboardCookieJar.new);

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
  /// answer's cookies, in [root]'s jar, only if no purge started since, in
  /// turn with the commits and clears.
  HermesDashboardCookieIntake _intake(Uri root) {
    final origin = root.toString();
    if (_purgePending(origin)) {
      throw StateError('The dashboard sign-in is being cleared.');
    }
    final ticket = _ticket(origin);
    return (url, setCookies) => _inTurn(() async {
      if (!_unpurged(origin, ticket)) return;
      final readable = await _read();
      if (!_jarFor(origin).absorb(url, setCookies) || !readable) return;
      await _saveRotated();
    });
  }

  /// The store could not be read at [open], nor since: it may hold what
  /// the jars do not, so it is not written until it is read.
  bool _unread;

  /// Origin keys cleared while the store was [_unread]: their stored
  /// cookies are dropped when it is read.
  final Set<String> _clearedUnread = {};

  /// The last write failed, or the store still holds what the jars dropped
  /// (an earlier form, a clear while unread): the jars are what it must
  /// hold, and the next write or purge writes them.
  bool _dirty;

  /// Every jar's cookies, for tests and diagnostics.
  List<HermesDashboardCookie> get cookies => [
    for (final jar in _jars.values) ...jar.cookies,
  ];

  /// Reads an [_unread] store: what it holds goes under the jars' newer
  /// cookies, except for origins cleared meanwhile. True once it is read
  /// (at once when it was), false while it still cannot be. In turn.
  Future<bool> _read() async {
    if (!_unread) return true;
    final String? source;
    try {
      source = await _store.read(key: kHermesDashboardCookiesKey);
    } on Object {
      return false;
    }
    final (stored, legacy) = _decode(source);
    if (legacy) _dirty = true;
    for (final MapEntry(key: origin, value: jar) in stored.entries) {
      if (_clearedUnread.contains(origin)) {
        _dirty = true;
        continue;
      }
      final held = _jars.putIfAbsent(origin, HermesDashboardCookieJar.new);
      final newer = {for (final cookie in held.cookies) cookie.identity};
      for (final cookie in jar.cookies) {
        if (!newer.contains(cookie.identity)) held.put(cookie);
      }
    }
    _clearedUnread.clear();
    _unread = false;
    return true;
  }

  /// Writes the jars after the writes before it. A write that fails fails
  /// its caller (and marks the store [_dirty]); the next write still runs.
  /// Never while [_unread].
  Future<void> _save() {
    final kept = {
      for (final MapEntry(:key, :value) in _jars.entries)
        if (!value.isEmpty) key: value.toJson(),
    };
    final value = kept.isEmpty ? null : jsonEncode(kept);
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

  /// A purge's write: needed when [removed] changed a jar or the store
  /// still holds what the jars do not. True once the secure store holds
  /// what the jars do. The store is read first ([_read]).
  Future<bool> _purged(bool removed) async {
    if (!await _read()) return false;
    if (!removed && !_dirty) return true;
    try {
      await _save();
      return true;
    } on Object {
      return false;
    }
  }

  /// The commit point: takes [cookies], a sign-in window's for [root]'s
  /// host, into [root]'s jar, while sign-in [generation] is still [root]'s
  /// latest, no purge started since [ticket], and [wanted] still holds,
  /// checked in turn right before the jar changes. True when a session
  /// cookie was among them; false, with nothing taken, once superseded or
  /// unwanted. A save that fails (or a store that cannot be read, so not
  /// written) puts the jar back and is thrown.
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
      if (!await _read()) {
        throw StateError('The dashboard cookies could not be read.');
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
      final jar = _jarFor(origin);
      final replaced = {
        for (final cookie in jar.cookies) cookie.identity: cookie,
      };
      for (final cookie in taken) {
        jar.put(cookie);
      }
      try {
        await _save();
      } on Object {
        final identities = {for (final cookie in taken) cookie.identity};
        jar.removeAll(identities);
        for (final identity in identities) {
          final before = replaced[identity];
          if (before != null) jar.put(before);
        }
        rethrow;
      }
      return taken.any((cookie) => _isSessionCookie(cookie.name));
    });
  }

  /// Whether a dashboard session for [baseUrl]'s dashboard is held, in its
  /// own jar.
  bool hasSession(String baseUrl) {
    final root = hermesDashboardRoot(baseUrl);
    final jar = _jars[_originKey(root.toString())];
    if (jar == null) return false;
    final held = jar.identitiesFor(root.host);
    return jar.cookies.any(
      (cookie) =>
          _isSessionCookie(cookie.name) && held.contains(cookie.identity),
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
    jar: _jarFor(root.toString()),
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
    jar: _jarFor(root.toString()),
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

  /// None: the core asks for the cookies of [origin]'s host that a clear
  /// could not tell from another gateway's there (a WebView's store holds
  /// every origin's together, so it asks Hermes to sign such a session
  /// out). Here each origin's cookies are in a jar of their own, which
  /// [clearForOrigin] deletes whole, so no cookie of another origin is
  /// held with them and none of its own is left.
  @override
  Future<Set<String>> identitiesFor(String origin) async => const {};

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
        final jar = _jars[key];
        removed =
            jar != null &&
            jar.removeAll({for (final cookie in jar.cookies) cookie.identity});
      } finally {
        final left = (_pendingPurges[key] ?? 1) - 1;
        if (left > 0) {
          _pendingPurges[key] = left;
        } else {
          _pendingPurges.remove(key);
        }
      }
      // Gone from the jar; the store, while unread, keeps them until it
      // is read (then they are dropped and written).
      if (_unread) _clearedUnread.add(key);
      return _purged(removed);
    });
  }

  /// Every cookie: the jars hold only dashboard sessions.
  @override
  Future<bool> clearCookies() => clearAll();

  @override
  Future<bool> clearWebsiteData() async => true;

  /// Empties every jar, superseding every sign-in still being checked, and
  /// the store with them, read or not.
  @override
  Future<bool> clearAll() {
    _epoch++;
    _pendingFullPurges++;
    return _inTurn(() {
      final bool removed;
      try {
        removed = _jars.values.fold(
          false,
          (changed, jar) =>
              jar.removeAll({for (final c in jar.cookies) c.identity}) ||
              changed,
        );
      } finally {
        _pendingFullPurges--;
      }
      // What an unread store holds goes too: nothing of it is kept.
      if (_unread) {
        _unread = false;
        _clearedUnread.clear();
        _dirty = true;
      }
      return _purged(removed);
    });
  }

  /// Writes a purge whose write failed before (or that waits for an
  /// unread store to be read).
  @override
  Future<bool> completePendingClear() => _inTurn(() async {
    if (_unread && _clearedUnread.isEmpty) return true;
    return _purged(false);
  });
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
