import 'dart:async';

/// The reads of one list the server gives (its models, tools or terminals),
/// numbered as they start.
///
/// A read that starts later asked the server later, so only the newest may
/// publish what it read or write it to the cache. An older read that answers
/// last keeps its result to itself. Starting a read is how a change on the
/// server, such as a device joining or leaving, supersedes one under way.
///
/// Cache writes run one at a time, in the order they were asked for, and
/// each only if its read is still the newest when its turn comes.
///
/// Riverpod retires a provider build without stopping it. A read made for a
/// build passes `current`, whether that build is still the provider's own,
/// and counts as superseded once it is not.
final class ListLoads {
  int _newest = 0;
  Completer<void> _newestDone = Completer<void>()..complete();
  Completer<void> _nextStart = Completer<void>();
  Future<void> _writes = Future<void>.value();
  int _pendingWrites = 0;

  /// Starts a read, superseding every one before it.
  ListLoad start({bool Function()? current}) {
    final done = Completer<void>();
    _newestDone = done;
    final started = _nextStart;
    _nextStart = Completer<void>();
    started.complete();
    return ListLoad._(this, ++_newest, done, current);
  }

  /// For a write that is no read's result, such as emptying the cache on
  /// sign-out: it is made only while no read starts from now on.
  ListLoad sinceNow({bool Function()? current}) =>
      ListLoad._(this, _newest, null, current);

  /// Stands for the cache as read now, so what was read can be written back.
  /// That is made only if no read or write was under way when it was read,
  /// and no read starts meanwhile.
  ListLoad cacheAsRead({bool Function()? current}) {
    final quiet = _newestDone.isCompleted && _pendingWrites == 0;
    return ListLoad._(this, quiet ? _newest : -1, null, current);
  }

  /// Completes once the newest read has finished, including one that starts
  /// meanwhile; an older read still under way is not waited for.
  Future<void> settled() async {
    while (!_newestDone.isCompleted) {
      await Future.any([_newestDone.future, _nextStart.future]);
    }
  }
}

/// One read of a list ([ListLoads.start]).
final class ListLoad {
  ListLoad._(this._loads, this._number, this._done, this._current);

  final ListLoads _loads;
  final int _number;
  final Completer<void>? _done;
  final bool Function()? _current;

  /// No read started after this one, and the build it was made for, if
  /// any, is still current.
  bool get isNewest => _loads._newest == _number && (_current?.call() ?? true);

  /// Runs [save] after every cache write asked for before it, if this read
  /// is still the newest by then.
  Future<void> write(Future<void> Function() save) {
    final loads = _loads;
    loads._pendingWrites++;
    final queued = loads._writes.then<void>((_) async {
      try {
        if (isNewest) await save();
      } finally {
        loads._pendingWrites--;
      }
    });
    loads._writes = queued.then<void>((_) {}, onError: (Object _) {});
    return queued;
  }

  /// Ends this read. [ListLoads.settled] waits for it while it is the newest.
  void finish() {
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
  }
}
