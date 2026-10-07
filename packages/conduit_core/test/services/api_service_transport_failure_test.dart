import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Every request fails before reaching a server, as when the address in use
/// stopped answering.
final class _Unreachable implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw DioException.connectionError(
    requestOptions: options,
    reason: 'Connection refused',
  );

  @override
  void close({bool force = false}) {}
}

/// A request that cannot reach the server is what tells the app the address
/// in use may be gone: connectivity checks the server, and the route
/// resolver tries its other addresses.
void main() {
  test('a request that cannot reach the server is reported', () async {
    final workerManager = WorkerManager(worker: const InlineWorkerPort());
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server',
        name: 'Server',
        url: 'http://10.0.0.2:3000',
      ),
      workerManager: workerManager,
    );
    api.dio.httpClientAdapter = _Unreachable();
    api.updateAuthToken('session-token');
    final reported = <Uri>[];
    final reports = ConnectivityService.transportFailures.listen(reported.add);
    addTearDown(() async {
      await reports.cancel();
      api.dispose();
      workerManager.dispose();
    });

    await check(api.getCurrentUser()).throws<DioException>();

    check(reported).deepEquals([Uri.parse('http://10.0.0.2:3000')]);
  });
}
