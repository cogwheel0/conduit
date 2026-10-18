import 'dart:async';
import 'dart:convert';

import 'package:synchronized/synchronized.dart';

import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// The saved LibreChat accounts, in secure storage under
/// `librechat_registry_v1`. Their sessions sit beside it, one entry per
/// account (`librechat_session_v1:<accountId>`).
final class LibreChatRegistryStore {
  LibreChatRegistryStore(this._store);

  final SecureKeyValueStore _store;
  final Lock _lock = Lock();

  static const String key = 'librechat_registry_v1';

  Future<LibreChatRegistry> read() => _lock.synchronized(_read);

  Future<LibreChatRegistry> _read() async {
    final raw = await _store.read(key: key);
    if (raw == null || raw.isEmpty) return const LibreChatRegistry();
    try {
      return LibreChatRegistry.fromJson(jsonDecode(raw));
    } on FormatException {
      DebugLogger.warning('registry-unreadable', scope: 'librechat/registry');
      return const LibreChatRegistry();
    }
  }

  /// Applies [change] to the saved registry and saves the result, one change
  /// at a time.
  Future<LibreChatRegistry> update(
    LibreChatRegistry Function(LibreChatRegistry current) change,
  ) => _lock.synchronized(() async {
    final next = change(await _read());
    await _store.write(key: key, value: jsonEncode(next.toJson()));
    return next;
  });

  /// The session store of account [accountId].
  LibreChatSessionStore sessionStore(String accountId) => _GatedSessionStore(
    SecureLibreChatSessionStore(_store, accountId),
    this,
    accountId,
    _signOuts[accountId] ?? 0,
  );

  /// How many times each account was signed out in this run. A store handed
  /// out before one of them writes nothing after it.
  final Map<String, int> _signOuts = <String, int>{};

  /// Before account [accountId] is signed out or signed in to again: refuses
  /// session writes and clears from every store handed out for it so far --
  /// a session switched away from can still be saving a renewal or a cookie,
  /// or ending -- and waits for those already under way, so none lands after
  /// this. A store asked for after this works as usual.
  Future<void> retireSessionStores(String accountId) async {
    _signOuts[accountId] = (_signOuts[accountId] ?? 0) + 1;
    await Future.wait([..._sessionWrites, ..._sessionClears]);
  }

  bool _sessionWritesBlocked = false;

  /// Session writes under way, which a block or a retirement waits for.
  final Set<Future<void>> _sessionWrites = <Future<void>>{};

  /// Session clears under way, which a retirement waits for. A full
  /// sign-out deletes every session itself, and does not wait on them.
  final Set<Future<void>> _sessionClears = <Future<void>>{};

  static void _track(Set<Future<void>> changes, Future<void> change) {
    final settled = change.then<void>((_) {}, onError: (Object _) {});
    changes.add(settled);
    unawaited(settled.whenComplete(() => changes.remove(settled)));
  }

  /// Full sign-outs begun in this run. A save that waited across one would
  /// put back what it cleared.
  int get clears => _clears;
  int _clears = 0;

  /// Before a full sign-out clears storage: refuses every session write from
  /// now on and waits for those already saving, so none lands after the
  /// clear -- a sign-in finishing, or a live session saving a renewal.
  Future<void> blockSessionWrites() async {
    _sessionWritesBlocked = true;
    _clears++;
    await Future.wait(_sessionWrites.toList(growable: false));
  }

  /// The clear is over or did not happen: sessions save again.
  void allowSessionWrites() => _sessionWritesBlocked = false;

  /// Removes the registry and every LibreChat session, including any left
  /// behind by an account no longer in the registry.
  Future<void> deleteAll() => _lock.synchronized(() async {
    final all = await _store.readAll();
    for (final entry in all.keys) {
      if (entry == key ||
          entry.startsWith(SecureLibreChatSessionStore.keyPrefix)) {
        await _store.delete(key: entry);
      }
    }
  });
}

/// Session writes that [LibreChatRegistryStore.blockSessionWrites] can stop
/// and wait for.
final class _GatedSessionStore implements LibreChatSessionStore {
  _GatedSessionStore(
    this._inner,
    this._owner,
    this._accountId,
    this._signOuts,
  );

  final LibreChatSessionStore _inner;
  final LibreChatRegistryStore _owner;
  final String _accountId;

  /// The account's sign-outs when this store was handed out.
  final int _signOuts;

  @override
  Future<LibreChatSession?> read() => _inner.read();

  @override
  Future<void> write(LibreChatSession session) {
    if (_owner._sessionWritesBlocked) {
      return Future.error(StateError('LibreChat accounts are being cleared.'));
    }
    if ((_owner._signOuts[_accountId] ?? 0) != _signOuts) {
      return Future.error(StateError('This LibreChat account signed out.'));
    }
    final write = _inner.write(session);
    LibreChatRegistryStore._track(_owner._sessionWrites, write);
    return write;
  }

  /// Does nothing once the account was signed out or signed in to again
  /// since this store was handed out: a session that was replaced, ending,
  /// must not take its successor with it.
  @override
  Future<void> clear() {
    if ((_owner._signOuts[_accountId] ?? 0) != _signOuts) {
      return Future<void>.value();
    }
    final clear = _inner.clear();
    LibreChatRegistryStore._track(_owner._sessionClears, clear);
    return clear;
  }
}
