import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/ports/connectivity_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/testing.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  setUp(ConnectivityService.debugResetTrafficSignals);

  /// The account's server gone, with the network up: the service has probed
  /// it three times, failed each time, and marked it offline.
  ({ConnectivityService service, _Server server, AppDatabase db}) serverGone(
    FakeAsync async,
  ) {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final server = _Server();
    final dio = Dio()..httpClientAdapter = server;
    final network = _Network();
    addTearDown(network.dispose);
    final container = ProviderContainer(
      overrides: [
        activeServerProvider.overrideWith(
          (_) async => const ServerConfig(
            id: 'server',
            name: 'Server',
            url: 'https://server.example',
          ),
        ),
        apiServiceProvider.overrideWithValue(null),
        appDatabaseProvider.overrideWithValue(db),
      ],
    );
    addTearDown(container.dispose);
    unawaited(container.read(activeServerProvider.future));
    async.flushMicrotasks();
    final serviceProvider = Provider<ConnectivityService>((ref) {
      final service = ConnectivityService(
        dio,
        ref,
        network,
        false,
        FakeAppLifecycle(),
      );
      ref.onDispose(service.dispose);
      return service;
    });
    // Held as the app holds it, through the connectivity status it watches.
    final service = container.listen(serviceProvider, (_, _) {}).read();
    async.elapse(const Duration(seconds: 10));
    check(server.probes).equals(3);
    check(service.currentStatus).equals(ConnectivityStatus.offline);
    return (service: service, server: server, db: db);
  }

  /// An update queued for [chatId], then [settle]d.
  int queue(
    FakeAsync async,
    AppDatabase db,
    _Settle settle, {
    String chatId = 'chat-1',
  }) {
    int? seq;
    unawaited(() async {
      final queued = await db.outboxDao.enqueue(
        kind: OutboxKind.updateChat,
        chatId: chatId,
      );
      await settle(db.outboxDao, queued);
      seq = queued;
    }());
    async.elapse(Duration.zero);
    return seq!;
  }

  // The drainer puts an op off as offline once the server is known to be
  // unreachable; one it tried before that failed to reach it.
  for (final (label, settle) in <(String, _Settle)>[
    ('put off as offline', _putOff),
    (
      'that failed to reach it',
      (dao, seq) => dao.markFailedRetryable(
        seq,
        error: 'DioException [connection error]',
        nextAttemptAt: 0,
      ),
    ),
  ]) {
    test(
      'a server that cannot be reached is probed about every 30 s while an '
      'update $label waits to be sent to it, from the moment it is queued',
      () {
        fakeAsync((async) {
          final (service: _, :server, :db) = serverGone(async);

          queue(async, db, settle);
          async.elapse(const Duration(seconds: 36));
          check(server.probes).equals(4);
          async.elapse(const Duration(seconds: 36));
          check(server.probes).equals(5);
        });
      },
    );
  }

  for (final (label, queueWork)
      in <(String, void Function(FakeAsync, AppDatabase))>[
        ('nothing is queued', (_, _) {}),
        ('only a parked op is queued', (async, db) => queue(async, db, _park)),
        (
          'only an update held up behind a parked op of its chat is queued',
          (async, db) {
            queue(async, db, _park);
            queue(async, db, _putOff);
          },
        ),
      ]) {
    test('a server that cannot be reached is probed about every 2 minutes '
        'when $label', () {
      fakeAsync((async) {
        final (service: _, :server, :db) = serverGone(async);
        queueWork(async, db);

        async.elapse(const Duration(seconds: 85));
        check(server.probes).equals(3);
        async.elapse(const Duration(seconds: 60));
        check(server.probes).equals(4);
      });
    });
  }

  test('once nothing waits to be sent, the server is probed about every 2 '
      'minutes again', () {
    fakeAsync((async) {
      final (service: _, :server, :db) = serverGone(async);
      final seq = queue(async, db, _putOff);
      async.elapse(const Duration(seconds: 36));
      check(server.probes).equals(4);

      // The update leaves the outbox while the server is still away.
      unawaited(db.outboxDao.markDone(seq));
      async.elapse(const Duration(seconds: 90));
      check(server.probes).equals(4);
      async.elapse(const Duration(seconds: 60));
      check(server.probes).equals(5);
    });
  });
}

Future<void> _putOff(OutboxDao dao, int seq) =>
    dao.markOfflineDeferred(seq, nextAttemptAt: 0);

Future<void> _park(OutboxDao dao, int seq) =>
    dao.markParked(seq, error: 'not the owner');

/// What the drainer made of a queued op.
typedef _Settle = Future<void> Function(OutboxDao dao, int seq);

/// The account's server, gone: each health probe is answered 503.
final class _Server implements HttpClientAdapter {
  int probes = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    probes += 1;
    return ResponseBody.fromString('', 503);
  }

  @override
  void close({bool force = false}) {}
}

/// A network that is up and never changes.
final class _Network implements ConnectivityPort {
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  @override
  Future<bool> hasNetworkInterface() async => true;

  @override
  Stream<bool> get onChanged => _changes.stream;

  Future<void> dispose() => _changes.close();
}
