import 'dart:async';

import 'package:synchronized/synchronized.dart';

import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Renews [current]'s access token with the server. Throws
/// [LibreChatSessionExpiredException] when the session is over, and anything
/// else when the attempt failed but the session may still be good.
typedef LibreChatSessionRenewer =
    Future<LibreChatSession> Function(LibreChatSession current);

/// The live session of one signed-in LibreChat account, shared by every
/// request to its server.
///
/// LibreChat rotates the refresh cookie each time it renews the access token
/// and forgets the one it replaced, so two renewals racing each other would
/// leave whichever lost holding a dead cookie and its account signed out.
/// Renewal is therefore single-flight, and a renewed session is saved before
/// anything that waited on it runs again. A crash between the server's
/// rotation and that save is the only way left to lose the cookie.
final class LibreChatSessionHandle {
  LibreChatSessionHandle({
    required LibreChatSession session,
    required LibreChatSessionStore store,
    required LibreChatSessionRenewer renew,
    DateTime Function()? clock,
  }) : _current = session,
       _store = store,
       _renew = renew,
       _clock = clock ?? DateTime.now;

  LibreChatSession? _current;
  final LibreChatSessionStore _store;
  final LibreChatSessionRenewer _renew;
  final DateTime Function() _clock;
  final Lock _saveLock = Lock();
  final StreamController<LibreChatSession?> _changes =
      StreamController<LibreChatSession?>.broadcast(sync: true);
  Future<LibreChatSession>? _renewal;

  /// The current session failed to reach the store and is written again on
  /// the next use.
  bool _unsaved = false;

  /// The session has ended but the store still holds it: clearing it failed,
  /// and the next [end] tries again.
  bool _clearPending = false;

  /// The session, or null once it has ended.
  LibreChatSession? get current => _current;

  bool get isEnded => _current == null;

  /// Every change to [current]: a renewal, new cookies, or null at the end.
  Stream<LibreChatSession?> get changes => _changes.stream;

  /// The session with an access token good for a while yet: [current], or a
  /// renewed one when its token is about to lapse.
  ///
  /// Renewing ahead of time saves a refused request, and matters most for a
  /// stream, which cannot be replayed once it has started. When that early
  /// renewal fails for a reason that may pass, the current token is still
  /// tried and the server decides.
  Future<LibreChatSession> fresh() async {
    if (_unsaved) await _save((latest) => latest);
    final session = _requireCurrent();
    if (!session.accessTokenExpiresSoon(_clock())) return session;
    try {
      return await _renewOnce(session);
    } on LibreChatSessionExpiredException {
      rethrow;
    } catch (error) {
      DebugLogger.warning(
        'early-renewal-failed',
        scope: 'librechat/session',
        data: {'error': error.runtimeType.toString()},
      );
      return _requireCurrent();
    }
  }

  /// Renews after the server refused [staleToken]. When the session has
  /// already moved past that token (another request renewed it), returns the
  /// newer session without asking the server again. An ended session fails
  /// the returned future, as [fresh] does.
  Future<LibreChatSession> renewAfterRefusal(String staleToken) async {
    final session = _requireCurrent();
    if (session.accessToken != staleToken) return session;
    return _renewOnce(session);
  }

  Future<LibreChatSession> _renewOnce(LibreChatSession session) {
    final inFlight = _renewal;
    if (inFlight != null) return inFlight;
    final renewal = _runRenewal(session);
    _renewal = renewal;
    // Cleared once settled, success or failure, so the next refusal can try
    // again.
    renewal.then<void>(
      (_) => _clearRenewal(renewal),
      onError: (Object _) => _clearRenewal(renewal),
    );
    return renewal;
  }

  void _clearRenewal(Future<LibreChatSession> renewal) {
    if (identical(_renewal, renewal)) _renewal = null;
  }

  Future<LibreChatSession> _runRenewal(LibreChatSession session) async {
    final LibreChatSession renewed;
    try {
      renewed = await _renew(session);
    } on LibreChatSessionExpiredException {
      // The session is over whether or not the store forgets it now (a
      // later end tries again); callers still learn it expired.
      try {
        await end();
      } catch (error) {
        DebugLogger.warning(
          'session-clear-failed',
          scope: 'librechat/session',
          data: {'error': error.runtimeType.toString()},
        );
      }
      rethrow;
    }
    if (_current == null) {
      // Signed out while the renewal ran. Its cookie is not kept.
      throw const LibreChatSessionExpiredException();
    }
    // Onto the session as it is now: cookies another response set while the
    // renewal ran stay, with the renewal's own changes on top.
    final saved = await _save(
      (latest) => renewed.copyWith(
        cookies: latest.cookies.withChanges(
          base: session.cookies,
          changed: renewed.cookies,
        ),
      ),
    );
    return saved ?? (throw const LibreChatSessionExpiredException());
  }

  /// Folds a response's `Set-Cookie` [headers] into the session and saves it
  /// when they changed anything.
  Future<void> absorbCookies(Iterable<String> headers) async {
    if (headers.isEmpty || _current == null) return;
    await _save((latest) {
      final cookies = latest.cookies.apply(headers, now: _clock());
      return identical(cookies, latest.cookies)
          ? latest
          : latest.copyWith(cookies: cookies);
    });
  }

  /// Ends the session here: forgets it in memory and in the store. Signing
  /// out on the server is the caller's to do first.
  ///
  /// When the store refuses to forget it, the session still ends here and a
  /// later call clears the store again, so a restart cannot bring it back.
  Future<void> end() async {
    if (_current == null && !_clearPending) return;
    // Pending before anyone hears of it: a listener that throws still
    // leaves the clear to be retried.
    _clearPending = true;
    if (_current != null) {
      _current = null;
      _unsaved = false;
      _publish(null);
    }
    await _saveLock.synchronized(() async {
      if (!_clearPending) return;
      await _store.clear();
      _clearPending = false;
    });
  }

  /// Applies [change] to the session as it is when its turn comes, stores the
  /// result, then makes it [current]. Changes run one at a time, each onto
  /// the one before, so the store only ever moves forward. Returns the
  /// session saved, or null when the session ended first.
  ///
  /// Stored before it is published: a request never goes out on a renewed
  /// session the store does not hold. When the store refuses the write, the
  /// session still becomes current -- the server has already rotated the
  /// refresh cookie it carries, and dropping it would end the session -- and
  /// the write is tried again on the next use.
  Future<LibreChatSession?> _save(
    LibreChatSession Function(LibreChatSession latest) change,
  ) => _saveLock.synchronized(() async {
    final latest = _current;
    if (latest == null) return null;
    final next = change(latest);
    if (identical(next, latest) && !_unsaved) return latest;
    try {
      await _store.write(next);
      _unsaved = false;
    } catch (error) {
      _unsaved = true;
      DebugLogger.warning(
        'session-save-failed',
        scope: 'librechat/session',
        data: {'error': error.runtimeType.toString()},
      );
    }
    if (_current == null) return null;
    _current = next;
    if (!identical(next, latest)) _publish(next);
    return next;
  });

  void _publish(LibreChatSession? session) {
    if (!_changes.isClosed) _changes.add(session);
  }

  LibreChatSession _requireCurrent() =>
      _current ?? (throw const LibreChatSessionExpiredException());

  Future<void> dispose() => _changes.close();
}
