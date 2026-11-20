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
final class ListLoads {
  int _newest = 0;
  Completer<void> _newestDone = Completer<void>()..complete();
  Future<void> _writes = Future<void>.value();
  int _pendingWrites = 0;

  /// Starts a read, superseding every one before it.
  ListLoad start() {
    final done = Completer<void>();
    _newestDone = done;
    return ListLoad._(this, ++_newest, done);
  }

  /// For a write that is no read's result, such as emptying the cache on
  /// sign-out: it is made only while no read starts from now on.
  ListLoad sinceNow() => ListLoad._(this, _newest, null);

  /// Stands for the cache as read now, so what was read can be written back.
  /// That is made only if no read or write was under way when it was read,
  /// and no read starts meanwhile.
  ListLoad cacheAsRead() {
    final quiet = _newestDone.isCompleted && _pendingWrites == 0;
    return ListLoad._(this, quiet ? _newest : -1, null);
  }

  /// Completes once the newest read has finished, including one that starts
  /// meanwhile.
  Future<void> settled() async {
    for (;;) {
      final done = _newestDone;
      await done.future;
      if (identical(done, _newestDone)) return;
    }
  }
}

/// One read of a list ([ListLoads.start]).
final class ListLoad {
  ListLoad._(this._loads, this._number, this._done);

  final ListLoads _loads;
  final int _number;
  final Completer<void>? _done;

  /// No read started after this one.
  bool get isNewest => _loads._newest == _number;

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
