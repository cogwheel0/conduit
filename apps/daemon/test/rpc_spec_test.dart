@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// The daemon answers exactly the methods the protocol's tables list, with
/// the tables' own decoders, so the Rust client generated from those tables
/// cannot call a method the daemon lacks or send params it reads otherwise.
void main() {
  late Directory tempDir;
  late RpcSession session;
  late json_rpc.Peer client;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('conduitd_rpc_spec');
    final log = DaemonLog(level: 'error', sink: NullSink());
    final pipe = StreamChannelController<String>(sync: true);
    session = RpcSession(
      sessionId: 'spec',
      channel: pipe.local,
      system: SystemService(
        directories: DaemonDirectories.create(tempDir.path),
        daemonVersion: '0.0.0-test',
        log: log,
        requestStop: (_) => fail('nothing here should stop the daemon'),
      ),
      events: EventBus(),
      log: log,
      // No core: every handler that reaches a service refuses, which is
      // all this file needs to tell a handler from the fallback.
      services: () => const CoreServices(),
    );
    unawaited(session.listen());
    client = json_rpc.Peer(pipe.foreign);
    unawaited(client.listen());
  });

  tearDown(() async {
    await client.close();
    await session.close();
    await tempDir.delete(recursive: true);
  });

  test('every specced method has a handler, and nothing else does', () {
    final registered = session.registeredMethods;
    final specced = <String>{
      for (final spec in ConduitMethodSpecs.all) spec.name,
    };
    expect(
      specced.difference(registered.keys.toSet()),
      isEmpty,
      reason: 'specced in conduit_protocol without a handler in the daemon',
    );
    expect(
      registered.keys.toSet().difference(specced),
      isEmpty,
      reason: 'registered by the daemon without a spec in conduit_protocol',
    );
  });

  test('every handler decodes with its spec\'s decoders', () {
    for (final MapEntry(key: name, value: registered)
        in session.registeredMethods.entries) {
      final spec = ConduitMethodSpecs.byName(name)!;
      expect(
        identical(registered, spec),
        isTrue,
        reason: '$name was registered from a different spec object',
      );
      expect(registered.params, spec.params, reason: '$name params decoder');
      expect(registered.result, spec.result, reason: '$name result decoder');
      expect(registered.paramsType, spec.paramsType, reason: name);
      expect(registered.resultType, spec.resultType, reason: name);
    }
  });

  test('handlers are registered on the socket, not only recorded', () async {
    // Before the handshake every handler refuses at once -- after decoding
    // its params, which `{}` fails for any method with a required field --
    // so this reaches each one without side effects. The fallback would
    // answer `unsupported` or `methodNotFound` instead.
    for (final spec in ConduitMethodSpecs.all) {
      final error = await _errorOf(client, spec.name);
      expect(
        error.code,
        isIn(<String>[
          ConduitErrorCodes.protocolViolation,
          ConduitErrorCodes.invalidParams,
        ]),
        reason: '${spec.name} answered ${error.code}: ${error.debugMessage}',
      );
    }

    // And a name in a reserved namespace with no spec does reach it.
    expect(
      (await _errorOf(client, 'chats.notAMethod')).code,
      ConduitErrorCodes.unsupported,
    );
  });

  test('params that do not decode are invalidParams', () async {
    final error = await _errorOf(
      client,
      ConduitMethods.systemHandshake,
      params: <String, dynamic>{'protocolVersion': 1},
    );
    expect(error.code, ConduitErrorCodes.invalidParams);
    expect(error.args['method'], ConduitMethods.systemHandshake);
  });

  test('handlers are added only through the specs', () {
    // A handler added with the peer's own API would answer a method the
    // tables do not list, and none of the checks above could see it.
    final source = File('lib/src/rpc_session.dart').readAsStringSync();
    for (final call in <String>[
      '.registerMethod(',
      'registerTypedMethod(',
      'registerTypedMethodNoParams',
      'registerTypedMethod<',
    ]) {
      expect(source, isNot(contains(call)), reason: call);
    }
  });
}

Future<RpcError> _errorOf(
  json_rpc.Peer peer,
  String method, {
  Map<String, dynamic> params = const <String, dynamic>{},
}) async {
  try {
    await peer.sendRequest(method, params);
  } on json_rpc.RpcException catch (error) {
    return RpcError.fromException(error);
  }
  fail('$method answered without an error');
}
