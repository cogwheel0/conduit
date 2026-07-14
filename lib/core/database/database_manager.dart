import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/server_config.dart';
import '../utils/debug_logger.dart';
import 'app_database.dart';

/// Owns the per-server [AppDatabase] lifecycle (CDT-RFC-001 §6, D-08).
///
/// One database is active at a time. A database retired by a server switch is
/// normally closed immediately, but a scoped [DatabaseLifetimeLease] keeps it
/// alive until the asynchronous write that owns the lease has settled. This
/// lets the next server become active without invalidating in-flight durable
/// work for the previous server.
class DatabaseManager {
  /// [databaseDirectory] and [openDatabase] are test seams; production code
  /// uses the defaults (`getApplicationSupportDirectory`, matching
  /// `AppDatabase.forServer`'s `driftDatabase(name:)` location).
  DatabaseManager({
    Future<Directory> Function()? databaseDirectory,
    AppDatabase Function(String fileName)? openDatabase,
    String Function(String serverId)? databaseFileName,
  }) : _databaseDirectory = databaseDirectory ?? getApplicationSupportDirectory,
       _openDatabase = openDatabase ?? AppDatabase.forServer,
       _databaseFileName = databaseFileName ?? fileNameFor;

  final Future<Directory> Function() _databaseDirectory;
  final AppDatabase Function(String fileName) _openDatabase;
  final String Function(String serverId) _databaseFileName;

  _ManagedDatabase? _active;
  final Map<_ManagedDatabase, Future<void>> _explicitCloseOperations =
      Map<_ManagedDatabase, Future<void>>.identity();
  final Map<String, _ManagedDatabase> _failedExplicitCloses =
      <String, _ManagedDatabase>{};
  final Map<String, _ManagedDatabase> _retired = <String, _ManagedDatabase>{};
  final Map<String, _ManagedDatabase> _draining = <String, _ManagedDatabase>{};
  final Map<String, _ManagedDatabase> _closing = <String, _ManagedDatabase>{};
  final Map<AppDatabase, _ManagedDatabase> _byDatabase =
      Map<AppDatabase, _ManagedDatabase>.identity();
  // Reverse ownership must outlive the operational map. `_byDatabase` is
  // removed immediately before physical close so no new lease can start, but
  // detached callbacks can still hold the executor and must never reinterpret
  // it as an unmanaged test database. Expando keeps that provenance without
  // retaining closed database objects.
  final Expando<String> _stableServerIdByDatabase = Expando<String>(
    'managed database server id',
  );
  final Map<String, String> _fileOwners = <String, String>{};
  final Map<String, _FailedDatabaseClose> _closeFailures =
      <String, _FailedDatabaseClose>{};
  final Map<String, _FailedCloseRetryOperation> _failedCloseRetryOperations =
      <String, _FailedCloseRetryOperation>{};
  final Map<String, Future<void>> _pendingDeletions = <String, Future<void>>{};
  final Map<String, String> _deletingFileOwners = <String, String>{};

  /// Sync, lazy-open accessor for [server]'s database.
  AppDatabase openFor(ServerConfig server) => openForServerId(server.id);

  /// Attempts to open [server]'s database without surfacing an expected
  /// lifecycle transition as a synchronous error.
  ///
  /// A rapid A -> B -> A switch can request A while its first executor is
  /// still closing. Opening another executor would race SQLite teardown, while
  /// a synchronous caller cannot await it. In that case this returns
  /// [DatabaseOpenDeferred] with the future after which the caller may retry.
  DatabaseOpenAttempt openForIfReady(ServerConfig server) =>
      openForServerIdIfReady(server.id);

  /// Server-id form of [openForIfReady].
  DatabaseOpenAttempt openForServerIdIfReady(String serverId) {
    final deletion = _pendingDeletions[serverId];
    if (deletion != null) {
      return DatabaseOpenDeferred(deletion);
    }
    final failedCloseRetry = _failedCloseRetryOperations[serverId];
    if (failedCloseRetry != null) {
      return DatabaseOpenDeferred(failedCloseRetry.outcome.then<void>((_) {}));
    }
    final draining = _draining[serverId];
    if (draining != null) {
      return DatabaseOpenDeferred(draining.closed.future);
    }
    final closing = _closing[serverId];
    if (closing != null) {
      return DatabaseOpenDeferred(closing.closed.future);
    }
    return DatabaseOpenReady(openForServerId(serverId));
  }

  /// Sync, lazy-open accessor when only the stable server id is available.
  ///
  /// Reactive callers that can tolerate temporary unavailability should use
  /// [openForServerIdIfReady]. This strict accessor intentionally rejects an
  /// overlapping close so non-reactive code cannot create a second executor
  /// for the same SQLite file.
  AppDatabase openForServerId(String serverId) {
    final fileName = _databaseFileName(serverId);
    final deletingOwner = _deletingFileOwners[fileName];
    if (deletingOwner != null) {
      throw StateError(
        'Database file $fileName is being deleted for logical id '
        '$deletingOwner.',
      );
    }
    if (_draining.containsKey(serverId)) {
      throw StateError(
        'Database for logical id $serverId is waiting for active leases to '
        'close.',
      );
    }
    if (_failedCloseRetryOperations.containsKey(serverId)) {
      throw StateError(
        'Database for logical id $serverId is retrying a failed close.',
      );
    }
    final closing = _closing[serverId];
    if (closing != null) {
      throw StateError('Database for logical id $serverId is still closing.');
    }
    final closeFailure = _closeFailures[serverId];
    if (closeFailure != null && !closeFailure.entry.closed.isCompleted) {
      // Do not reuse an executor until the failed close attempt has completely
      // unwound. In practice this window is only the close chain's finalizer,
      // but preserving it makes the ownership transition explicit.
      Error.throwWithStackTrace(closeFailure.error, closeFailure.stackTrace);
    }
    final owner = _fileOwners[fileName];
    if (owner != null && owner != serverId) {
      throw StateError(
        'Database file $fileName is already owned by logical id $owner.',
      );
    }

    final active = _active;
    if (active != null && active.serverId == serverId) {
      return active.database;
    }
    if (active != null) {
      _active = null;
      _retire(active);
    }

    // A failed close does not prove that the executor released its file. Reuse
    // that exact executor instead of opening a second connection to the same
    // path. If the executor was left unusable by the failed close, its next
    // operation will surface that concrete error and deleteFor can still retry
    // the close without unlinking the file prematurely.
    if (closeFailure != null &&
        identical(_closeFailures[serverId], closeFailure)) {
      _closeFailures.remove(serverId);
      final recovered = closeFailure.entry;
      if (identical(_failedExplicitCloses[serverId], recovered)) {
        _failedExplicitCloses.remove(serverId);
      }
      recovered.resetAfterFailedClose(isRetired: false, closeRequested: false);
      _active = recovered;
      _byDatabase[recovered.database] = recovered;
      DebugLogger.log(
        'reuse-after-close-failure',
        scope: 'db/manager',
        data: {'serverId': serverId},
      );
      return recovered.database;
    }

    // A leased database remains a valid connection while retired. Reuse that
    // exact instance when the user switches back before its lease is released.
    final retained = _retired.remove(serverId);
    if (retained != null && !retained.isClosing) {
      retained.isRetired = false;
      _active = retained;
      DebugLogger.log(
        'reuse-retained',
        scope: 'db/manager',
        data: {'serverId': serverId, 'leases': retained.leaseCount},
      );
      return retained.database;
    }

    DebugLogger.log('open', scope: 'db/manager', data: {'serverId': serverId});
    final claimedFile = owner == null;
    if (claimedFile) _fileOwners[fileName] = serverId;
    late final AppDatabase db;
    try {
      db = _openDatabase(fileName);
    } catch (_) {
      if (claimedFile) _fileOwners.remove(fileName);
      rethrow;
    }
    final entry = _ManagedDatabase(serverId: serverId, database: db);
    _active = entry;
    _byDatabase[db] = entry;
    _stableServerIdByDatabase[db] = serverId;
    return db;
  }

  /// Acquires a lifetime lease when [database] is owned by this manager.
  ///
  /// Provider tests often override an [AppDatabase] without its manager, so
  /// callers may use this best-effort form and receive `null`. Production
  /// databases opened by [openForServerId] always return a lease.
  DatabaseLifetimeLease? tryAcquireLease(AppDatabase database) {
    final entry = _byDatabase[database];
    if (entry == null ||
        entry.isClosing ||
        entry.closeRequested ||
        _pendingDeletions.containsKey(entry.serverId)) {
      return null;
    }
    entry.leaseCount += 1;
    DebugLogger.log(
      'lease-acquired',
      scope: 'db/manager',
      data: {'serverId': entry.serverId, 'leases': entry.leaseCount},
    );
    return DatabaseLifetimeLease._(this, entry);
  }

  /// Stable logical owner for every database instance opened by this manager.
  ///
  /// This intentionally remains available while and after physical close.
  /// Callers use a non-null value to require a fresh [tryAcquireLease]; a
  /// closing executor must never fall through an "unmanaged test database"
  /// compatibility path merely because its operational entry was removed.
  String? serverIdForDatabase(AppDatabase database) =>
      _byDatabase[database]?.serverId ?? _stableServerIdByDatabase[database];

  /// Closes the database that is active when this call begins and joins any
  /// unresolved explicit close/retry work already owned by this manager.
  ///
  /// Existing lifetime leases may finish, but this future does not complete
  /// until that exact executor has physically closed. If its close fails, a
  /// subsequent call retries the same executor without requiring a reopen.
  Future<void> closeActive() {
    final target = _active;
    if (target != null) {
      _active = null;
      _requestClose(target, reason: 'close-active');
      _trackExplicitClose(target);
    }

    return _settleOutstandingExplicitCloses();
  }

  Future<void> _settleOutstandingExplicitCloses() {
    final operations = <Future<void>>[];
    final explicitlyClosing = Set<_ManagedDatabase>.identity();
    for (final entry in _explicitCloseOperations.entries) {
      explicitlyClosing.add(entry.key);
      operations.add(entry.value);
    }
    final joinedRetryServers = <String>{};
    for (final operation in _failedCloseRetryOperations.values) {
      joinedRetryServers.add(operation.serverId);
      operations.add(
        _observeFailedCloseRetry(operation, recordExplicitFailure: true),
      );
    }
    final failures = Map<String, _ManagedDatabase>.of(_failedExplicitCloses);
    for (final entry in failures.entries) {
      if (explicitlyClosing.contains(entry.value) ||
          joinedRetryServers.contains(entry.key)) {
        continue;
      }
      final failure = _closeFailures[entry.key];
      if (failure == null || !identical(failure.entry, entry.value)) {
        if (identical(_failedExplicitCloses[entry.key], entry.value)) {
          _failedExplicitCloses.remove(entry.key);
        }
        continue;
      }
      final retry = _retryFailedCloseOperation(
        entry.key,
        failure,
        reason: 'close-active-retry',
      );
      joinedRetryServers.add(entry.key);
      operations.add(
        _observeFailedCloseRetry(retry, recordExplicitFailure: true),
      );
    }
    return operations.isEmpty
        ? Future<void>.value()
        : Future.wait<void>(operations);
  }

  Future<void> _trackExplicitClose(_ManagedDatabase target) {
    final existing = _explicitCloseOperations[target];
    if (existing != null) return existing;
    late final Future<void> tracked;
    tracked = _awaitExplicitClose(target).whenComplete(() {
      if (identical(_explicitCloseOperations[target], tracked)) {
        _explicitCloseOperations.remove(target);
      }
    });
    _explicitCloseOperations[target] = tracked;
    return tracked;
  }

  Future<void> _awaitExplicitClose(_ManagedDatabase target) async {
    final outcome = await target.closeOutcome.future;
    final error = outcome.error;
    if (error != null) {
      _failedExplicitCloses[target.serverId] = target;
      Error.throwWithStackTrace(error, outcome.stackTrace!);
    }
    if (identical(_failedExplicitCloses[target.serverId], target)) {
      _failedExplicitCloses.remove(target.serverId);
    }
  }

  /// Closes the active database when it belongs to [serverId], then deletes
  /// the database file plus its rollback-journal, `-wal`, and `-shm` siblings.
  ///
  /// `drift_flutter`'s `driftDatabase(name:)` stores the file as
  /// `<directory>/<name>.sqlite` (verified against drift_flutter 0.x
  /// `_openConnection`); WAL mode produces `.sqlite-wal` / `.sqlite-shm`
  /// siblings. NativeDatabase can also use SQLite's default rollback journal,
  /// which leaves a `.sqlite-journal` sibling after an unclean shutdown.
  Future<void> deleteFor(String serverId) {
    final pending = _pendingDeletions[serverId];
    if (pending != null) return pending;

    final fileName = _databaseFileName(serverId);
    final deletingOwner = _deletingFileOwners[fileName];
    if (deletingOwner != null) {
      return Future<void>.error(
        StateError(
          'Cannot delete database file $fileName while it is being deleted '
          'for logical id $deletingOwner.',
        ),
      );
    }

    final completer = Completer<void>();
    final deletion = completer.future;
    _pendingDeletions[serverId] = deletion;
    _deletingFileOwners[fileName] = serverId;
    unawaited(
      _runDeletion(
        serverId: serverId,
        fileName: fileName,
        deletion: deletion,
        completer: completer,
      ),
    );
    return deletion;
  }

  Future<void> _runDeletion({
    required String serverId,
    required String fileName,
    required Future<void> deletion,
    required Completer<void> completer,
  }) async {
    try {
      await _deleteFor(serverId, fileName);
      completer.complete();
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    } finally {
      if (identical(_pendingDeletions[serverId], deletion)) {
        _pendingDeletions.remove(serverId);
      }
      if (_deletingFileOwners[fileName] == serverId) {
        _deletingFileOwners.remove(fileName);
      }
    }
  }

  Future<void> _deleteFor(String serverId, String fileName) async {
    final owner = _fileOwners[fileName];
    if (owner != null && owner != serverId) {
      throw StateError(
        'Cannot delete database file $fileName owned by logical id $owner.',
      );
    }

    final priorFailure = _closeFailures[serverId];
    if (priorFailure != null) {
      await _retryFailedClose(serverId, priorFailure);
    }

    _ManagedDatabase? target;
    final active = _active;
    if (active?.serverId == serverId) {
      _active = null;
      target = active;
    } else {
      target =
          _retired.remove(serverId) ??
          _draining[serverId] ??
          _closing[serverId];
    }
    if (target != null) {
      _requestClose(target, reason: 'delete');
      // Deletion owns filesystem unlinking, but the executor close is still an
      // explicit manager operation. Register it so a concurrent closeActive()
      // joins this exact physical outcome instead of reporting success while
      // the deletion-owned close can still fail.
      await _trackExplicitClose(target);
    }

    // Only this logical database can own this file. Unrelated server databases
    // close independently, so a stuck executor for A cannot block deleting B.
    final closeFailure = _closeFailures[serverId];
    if (closeFailure != null) {
      Error.throwWithStackTrace(closeFailure.error, closeFailure.stackTrace);
    }
    final directory = await _databaseDirectory();
    final base = p.join(directory.path, '$fileName.sqlite');
    for (final path in [base, '$base-journal', '$base-wal', '$base-shm']) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
    if (owner == serverId) _fileOwners.remove(fileName);
    DebugLogger.log(
      'deleted',
      scope: 'db/manager',
      data: {'serverId': serverId},
    );
  }

  Future<void> _retryFailedClose(
    String serverId,
    _FailedDatabaseClose failure,
  ) async {
    final retry = _retryFailedCloseOperation(
      serverId,
      failure,
      reason: 'delete-retry',
    );
    await _observeFailedCloseRetry(retry, recordExplicitFailure: false);
  }

  _FailedCloseRetryOperation _retryFailedCloseOperation(
    String serverId,
    _FailedDatabaseClose failure, {
    required String reason,
  }) {
    final existing = _failedCloseRetryOperations[serverId];
    if (existing != null) return existing;

    late final _FailedCloseRetryOperation operation;
    final outcome = _runFailedCloseRetry(serverId, failure, reason: reason)
        .whenComplete(() {
          if (identical(_failedCloseRetryOperations[serverId], operation)) {
            _failedCloseRetryOperations.remove(serverId);
          }
        });
    operation = _FailedCloseRetryOperation(
      serverId: serverId,
      entry: failure.entry,
      outcome: outcome,
    );
    _failedCloseRetryOperations[serverId] = operation;
    return operation;
  }

  Future<_DatabaseCloseOutcome> _runFailedCloseRetry(
    String serverId,
    _FailedDatabaseClose failure, {
    required String reason,
  }) async {
    final entry = failure.entry;

    // A failure is recorded before the attempt's completion signals settle.
    // Wait before replacing those per-attempt completers.
    if (!entry.closed.isCompleted) {
      await entry.closed.future;
    }
    if (!identical(_closeFailures[serverId], failure)) {
      final latest = _closeFailures[serverId];
      return _DatabaseCloseOutcome(
        error: latest?.error,
        stackTrace: latest?.stackTrace,
      );
    }

    entry.resetAfterFailedClose(isRetired: true, closeRequested: true);
    _requestClose(entry, reason: reason);
    return entry.closeOutcome.future;
  }

  Future<void> _observeFailedCloseRetry(
    _FailedCloseRetryOperation operation, {
    required bool recordExplicitFailure,
  }) async {
    final outcome = await operation.outcome;
    final error = outcome.error;
    if (error != null) {
      if (recordExplicitFailure) {
        _failedExplicitCloses[operation.serverId] = operation.entry;
      }
      Error.throwWithStackTrace(error, outcome.stackTrace!);
    }
    if (identical(_failedExplicitCloses[operation.serverId], operation.entry)) {
      _failedExplicitCloses.remove(operation.serverId);
    }
  }

  void _retire(_ManagedDatabase entry, {String reason = 'server-switch'}) {
    if (entry.isClosing) return;
    entry.isRetired = true;
    DebugLogger.log(
      'retire',
      scope: 'db/manager',
      data: {
        'serverId': entry.serverId,
        'leases': entry.leaseCount,
        'reason': reason,
      },
    );
    if (entry.leaseCount > 0) {
      _retired[entry.serverId] = entry;
      return;
    }
    _scheduleClose(entry, reason: reason);
  }

  void _requestClose(_ManagedDatabase entry, {required String reason}) {
    if (entry.isClosing) return;
    entry.isRetired = true;
    entry.closeRequested = true;
    _retired.remove(entry.serverId);
    _draining[entry.serverId] = entry;
    DebugLogger.log(
      'drain',
      scope: 'db/manager',
      data: {
        'serverId': entry.serverId,
        'leases': entry.leaseCount,
        'reason': reason,
      },
    );
    if (entry.leaseCount == 0) {
      _scheduleClose(entry, reason: reason);
    }
  }

  void _releaseLease(_ManagedDatabase entry) {
    if (entry.leaseCount <= 0) return;
    entry.leaseCount -= 1;
    DebugLogger.log(
      'lease-released',
      scope: 'db/manager',
      data: {'serverId': entry.serverId, 'leases': entry.leaseCount},
    );
    if (entry.leaseCount == 0 && entry.isRetired) {
      // Relinquishing a lease is bookkeeping, not a request to await physical
      // SQLite teardown. Explicit close/delete callers already await this
      // entry's closeOutcome; ordinary cache operations must not be held by a
      // slow close after their query has completed.
      _scheduleClose(entry, reason: 'last-lease-released');
    }
  }

  Future<void> _scheduleClose(
    _ManagedDatabase entry, {
    required String reason,
  }) {
    if (entry.isClosing) return entry.closed.future;
    entry.isClosing = true;
    entry.closeRequested = true;
    _closing[entry.serverId] = entry;
    if (identical(_retired[entry.serverId], entry)) {
      _retired.remove(entry.serverId);
    }
    if (identical(_draining[entry.serverId], entry)) {
      _draining.remove(entry.serverId);
    }
    _byDatabase.remove(entry.database);
    DebugLogger.log(
      'close',
      scope: 'db/manager',
      data: {'serverId': entry.serverId, 'reason': reason},
    );
    final attempt = entry.closed;
    var closeSucceeded = false;
    Object? closeError;
    StackTrace? closeStackTrace;
    unawaited(
      Future<void>.sync(() async {
            await entry.database.close();
            closeSucceeded = true;
          })
          .catchError((Object error, StackTrace stackTrace) {
            closeError = error;
            closeStackTrace = stackTrace;
            // Ordinary server switches close in the background, so keep this
            // chain settled. A later privacy-sensitive deleteFor must still
            // observe the failure and refuse to remove/certify the database.
            _closeFailures[entry.serverId] = _FailedDatabaseClose(
              entry: entry,
              error: error,
              stackTrace: stackTrace,
            );
            DebugLogger.error(
              'close-failed',
              scope: 'db/manager',
              error: error,
              stackTrace: stackTrace,
              data: {'serverId': entry.serverId},
            );
          })
          .whenComplete(() {
            if (closeSucceeded) {
              final failure = _closeFailures[entry.serverId];
              if (failure != null && identical(failure.entry, entry)) {
                _closeFailures.remove(entry.serverId);
              }
            }
            if (identical(_closing[entry.serverId], entry)) {
              _closing.remove(entry.serverId);
            }
            if (!entry.closeOutcome.isCompleted) {
              entry.closeOutcome.complete(
                _DatabaseCloseOutcome(
                  error: closeError,
                  stackTrace: closeStackTrace,
                ),
              );
            }
            if (!attempt.isCompleted) attempt.complete();
          }),
    );
    return attempt.future;
  }

  /// Filesystem-safe, collision-free encoding of [serverId].
  static String fileNameFor(String serverId) {
    final encoded = base64Url.encode(utf8.encode(serverId)).replaceAll('=', '');
    return 'server_$encoded';
  }
}

/// Result of a non-blocking [DatabaseManager.openForServerIdIfReady] request.
sealed class DatabaseOpenAttempt {
  const DatabaseOpenAttempt();
}

/// The managed database was ready synchronously.
final class DatabaseOpenReady extends DatabaseOpenAttempt {
  const DatabaseOpenReady(this.database);

  final AppDatabase database;
}

/// A close or deletion owns the database path until [retryAfter] settles.
final class DatabaseOpenDeferred extends DatabaseOpenAttempt {
  const DatabaseOpenDeferred(this.retryAfter);

  final Future<void> retryAfter;
}

/// A scoped ownership token that keeps one managed database usable while its
/// asynchronous owner finishes durable work.
final class DatabaseLifetimeLease {
  DatabaseLifetimeLease._(this._manager, this._entry);

  final DatabaseManager _manager;
  final _ManagedDatabase _entry;
  bool _released = false;

  AppDatabase get database => _entry.database;

  Future<void> release() {
    if (_released) return Future<void>.value();
    _released = true;
    _manager._releaseLease(_entry);
    return Future<void>.value();
  }
}

final class _ManagedDatabase {
  _ManagedDatabase({required this.serverId, required this.database});

  final String serverId;
  final AppDatabase database;
  Completer<void> closed = Completer<void>();
  Completer<_DatabaseCloseOutcome> closeOutcome =
      Completer<_DatabaseCloseOutcome>();
  int leaseCount = 0;
  bool isRetired = false;
  bool isClosing = false;
  bool closeRequested = false;

  void resetAfterFailedClose({
    required bool isRetired,
    required bool closeRequested,
  }) {
    assert(isClosing);
    assert(closed.isCompleted);
    closed = Completer<void>();
    closeOutcome = Completer<_DatabaseCloseOutcome>();
    isClosing = false;
    this.isRetired = isRetired;
    this.closeRequested = closeRequested;
  }
}

final class _DatabaseCloseOutcome {
  const _DatabaseCloseOutcome({this.error, this.stackTrace});

  final Object? error;
  final StackTrace? stackTrace;
}

final class _FailedDatabaseClose {
  const _FailedDatabaseClose({
    required this.entry,
    required this.error,
    required this.stackTrace,
  });

  final _ManagedDatabase entry;
  final Object error;
  final StackTrace stackTrace;
}

final class _FailedCloseRetryOperation {
  const _FailedCloseRetryOperation({
    required this.serverId,
    required this.entry,
    required this.outcome,
  });

  final String serverId;
  final _ManagedDatabase entry;
  final Future<_DatabaseCloseOutcome> outcome;
}
