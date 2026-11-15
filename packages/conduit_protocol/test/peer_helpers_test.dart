import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:test/test.dart';

void main() {
  group('paramsToMap', () {
    test('passes named params through, and absent params are empty', () {
      expect(
        paramsToMap(json_rpc.Parameters('m', <String, Object?>{'force': true})),
        <String, Object?>{'force': true},
      );
      expect(paramsToMap(json_rpc.Parameters('m', null)), isEmpty);
    });

    // A DTO whose fields all have defaults would accept an empty map, and
    // its handler would run with arguments the caller never sent.
    test('refuses positional params', () {
      expect(
        () => paramsToMap(json_rpc.Parameters('m', <Object?>[true])),
        throwsFormatException,
      );
    });
  });

  group('RpcError.fromException', () {
    test("reads Conduit's error payload", () {
      final error = RpcError.fromException(
        const RpcError(code: ConduitErrorCodes.notFound).toException(),
      );
      expect(error.code, ConduitErrorCodes.notFound);
    });

    // A peer that uses Conduit's code with some other payload must still
    // surface as an RpcError, as callTyped and callVoid promise.
    test("is internal when Conduit's code carries another payload", () {
      for (final data in <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{'code': 7},
      ]) {
        final error = RpcError.fromException(
          json_rpc.RpcException(kConduitRpcErrorCode, 'odd', data: data),
        );
        expect(error.code, ConduitErrorCodes.internal, reason: '$data');
      }
    });
  });
}
