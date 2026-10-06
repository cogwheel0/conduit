import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';

void main() {
  test('tool personal valves use only the per-user routes', () async {
    final requests = <RequestOptions>[];
    final api = _api(
      _RecordingAdapter((request) {
        requests.add(request);
        if (request.path.endsWith('/valves/user/spec')) {
          return _json({
            'properties': {
              'token': {'type': 'string'},
            },
          });
        }
        return _json({'token': 'abc'});
      }),
    );

    final spec = await api.getUserToolValvesSpec('shared_tool');
    final values = await api.getUserToolValves('shared_tool');
    final saved = await api.updateUserToolValves('shared_tool', {'token': 'x'});

    check(spec!.properties.keys).deepEquals(['token']);
    check(values).deepEquals({'token': 'abc'});
    check(saved).deepEquals({'token': 'abc'});
    check(requests.map((r) => '${r.method} ${r.path}')).deepEquals([
      'GET /api/v1/tools/id/shared_tool/valves/user/spec',
      'GET /api/v1/tools/id/shared_tool/valves/user',
      'POST /api/v1/tools/id/shared_tool/valves/user/update',
    ]);
    check(requests.last.data as Map<String, dynamic>)
        .deepEquals({'token': 'x'});
  });

  test('function personal valves use the exact upstream routes', () async {
    final requests = <RequestOptions>[];
    final api = _api(
      _RecordingAdapter((request) {
        requests.add(request);
        if (request.path.endsWith('/valves/user/spec')) {
          return _json({
            'properties': {
              'region': {'type': 'string'},
            },
            'required': ['region'],
          });
        }
        return _json({'region': 'eu'});
      }),
    );

    final spec = await api.getUserFunctionValvesSpec('echo_pipe');
    final values = await api.getUserFunctionValves('echo_pipe');
    final saved = await api.updateUserFunctionValves('echo_pipe', {
      'region': 'us',
    });

    check(spec!.required).deepEquals(['region']);
    check(values).isNotNull().deepEquals({'region': 'eu'});
    check(saved).isNotNull().deepEquals({'region': 'eu'});
    check(requests.map((r) => '${r.method} ${r.path}')).deepEquals([
      'GET /api/v1/functions/id/echo_pipe/valves/user/spec',
      'GET /api/v1/functions/id/echo_pipe/valves/user',
      'POST /api/v1/functions/id/echo_pipe/valves/user/update',
    ]);
    check(requests.last.data as Map<String, dynamic>)
        .deepEquals({'region': 'us'});
  });

  test('null personal schema and values stay null for functions', () async {
    final api = _api(_RecordingAdapter((_) => _json(null)));

    check(await api.getUserFunctionValvesSpec('inactive')).isNull();
    check(await api.getUserFunctionValves('inactive')).isNull();
    check(await api.updateUserFunctionValves('inactive', {})).isNull();
  });

  test('null personal tool values read as empty rather than failing', () async {
    final api = _api(_RecordingAdapter((_) => _json(null)));

    check(await api.getUserToolValvesSpec('no_schema')).isNull();
    check(await api.getUserToolValves('no_schema')).deepEquals({});
    check(await api.updateUserToolValves('no_schema', {})).deepEquals({});
  });
}

ApiService _api(HttpClientAdapter adapter) {
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test',
      url: 'http://localhost:0',
    ),
    workerManager: WorkerManager(),
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return service;
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.handler);

  final ResponseBody Function(RequestOptions request) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? value, {int statusCode = 200}) => ResponseBody(
  Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(value)))),
  statusCode,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);
