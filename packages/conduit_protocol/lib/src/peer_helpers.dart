import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;

import 'events.dart';
import 'rpc_error.dart';
import 'specs.dart';

/// Decodes a method's parameter map into its DTO.
typedef ParamsDecoder<P> = P Function(Map<String, dynamic> json);

/// Encodes a method's result DTO into a JSON map.
typedef ResultEncoder<R> = Map<String, dynamic> Function(R result);

/// Normalizes `json_rpc_2`'s [json_rpc.Parameters] into a plain map.
///
/// Every Conduit method takes a named map. Absent params become an empty map,
/// so the DTO decoder produces the real "missing required field" error, about
/// the field the caller forgot rather than the shape. Positional params throw
/// a [FormatException]: a DTO whose fields all have defaults would otherwise
/// accept the empty map, and its handler would run with arguments the caller
/// never sent.
Map<String, dynamic> paramsToMap(json_rpc.Parameters params) {
  final value = params.value;
  if (value == null) return <String, dynamic>{};
  if (value is Map) return Map<String, dynamic>.from(value);
  throw FormatException(
    '${params.method} takes named params, not ${value.runtimeType}',
  );
}

/// Registers a method with typed params and a typed result.
///
/// Wraps every failure so nothing crosses the socket as a raw Dart exception:
///
/// * an [RpcError] thrown by the handler goes out verbatim;
/// * an [json_rpc.RpcException] (usually from a nested call) is passed through;
/// * anything else becomes [ConduitErrorCodes.internal] with the original
///   text in `debugMessage`, which lands in the local log and never in the UI.
void registerTypedMethod<P, R>(
  json_rpc.Peer peer,
  String name, {
  required ParamsDecoder<P> decodeParams,
  required ResultEncoder<R> encodeResult,
  required FutureOr<R> Function(P params) handler,
}) {
  peer.registerMethod(name, (json_rpc.Parameters params) async {
    try {
      return encodeResult(await handler(decodeParams(paramsToMap(params))));
    } on RpcError catch (error) {
      throw error.toException();
    } on json_rpc.RpcException {
      rethrow;
    } catch (error, stack) {
      throw RpcError(
        code: ConduitErrorCodes.internal,
        debugMessage: '$error\n$stack',
      ).toException();
    }
  });
}

/// Registers a method that takes no parameters. Whatever params it is sent
/// are ignored.
void registerTypedMethodNoParams<R>(
  json_rpc.Peer peer,
  String name, {
  required ResultEncoder<R> encodeResult,
  required FutureOr<R> Function() handler,
}) {
  peer.registerMethod(name, (json_rpc.Parameters params) async {
    try {
      return encodeResult(await handler());
    } on RpcError catch (error) {
      throw error.toException();
    } on json_rpc.RpcException {
      rethrow;
    } catch (error, stack) {
      throw RpcError(
        code: ConduitErrorCodes.internal,
        debugMessage: '$error\n$stack',
      ).toException();
    }
  });
}

/// Registers the handler for [spec]'s method: params decoded with the
/// spec's own decoder, the result DTO encoded with its `toJson`.
///
/// Failures cross the socket as [registerTypedMethod]'s do, except that
/// params which fail to decode -- a missing field, a wrong type -- are
/// [ConduitErrorCodes.invalidParams] rather than an internal error: the
/// caller sent them, and nothing inside the daemon went wrong.
void registerSpecMethod<P, R>(
  json_rpc.Peer peer,
  ConduitMethodSpec<P, R> spec,
  FutureOr<R> Function(P params) handler,
) {
  final decode = spec.params;
  peer.registerMethod(spec.name, (json_rpc.Parameters params) async {
    final P decoded;
    try {
      // A method that takes no params ignores whatever it is sent.
      decoded = decode == null ? null as P : decode(paramsToMap(params));
    } catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'method': spec.name},
        debugMessage: '${spec.name}: $error',
      ).toException();
    }
    try {
      final result = await handler(decoded);
      return spec.result == null
          ? const <String, dynamic>{}
          : encodeDto(result as Object);
    } on RpcError catch (error) {
      throw error.toException();
    } on json_rpc.RpcException {
      rethrow;
    } catch (error, stack) {
      throw RpcError(
        code: ConduitErrorCodes.internal,
        debugMessage: '$error\n$stack',
      ).toException();
    }
  });
}

/// Encodes a protocol DTO: every one has a `toJson` returning plain JSON.
Map<String, dynamic> encodeDto(Object dto) =>
    (dto as dynamic).toJson() as Map<String, dynamic>;

/// Calls [spec]'s method and decodes the reply with the spec's decoder.
///
/// Every failure surfaces as an [RpcError], as with [callTyped].
Future<R> callSpec<P, R>(
  json_rpc.Peer peer,
  ConduitMethodSpec<P, R> spec, [
  P? params,
]) async {
  final decode = spec.result;
  final sent = params == null
      ? const <String, dynamic>{}
      : encodeDto(params as Object);
  if (decode == null) {
    await callVoid(peer, spec.name, params: sent);
    return null as R;
  }
  return callTyped<R>(peer, spec.name, params: sent, decodeResult: decode);
}

/// Calls [name] and decodes the reply.
///
/// Every failure surfaces as an [RpcError], so callers write one catch clause
/// instead of distinguishing transport faults from application errors.
Future<R> callTyped<R>(
  json_rpc.Peer peer,
  String name, {
  Map<String, dynamic>? params,
  required R Function(Map<String, dynamic> json) decodeResult,
}) async {
  try {
    final raw = await peer.sendRequest(
      name,
      params ?? const <String, dynamic>{},
    );
    return decodeResult(
      raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{},
    );
  } on RpcError {
    rethrow;
  } catch (error) {
    throw RpcError.fromException(error);
  }
}

/// Calls [name] and ignores the reply.
Future<void> callVoid(
  json_rpc.Peer peer,
  String name, {
  Map<String, dynamic>? params,
}) async {
  try {
    await peer.sendRequest(name, params ?? const <String, dynamic>{});
  } on RpcError {
    rethrow;
  } catch (error) {
    throw RpcError.fromException(error);
  }
}

/// The single JSON-RPC notification name every event travels under.
///
/// One name rather than one per event keeps the client's dispatch table in
/// Dart — where [ConduitEvents] can be exhaustively checked — instead of
/// spread across `registerMethod` calls that fail silently when misspelled.
const String kEventNotification = 'event';

/// Pushes [envelope] to a peer as a notification.
void sendEvent(json_rpc.Peer peer, EventEnvelope envelope) {
  peer.sendNotification(kEventNotification, envelope.toJson());
}

/// Routes incoming event notifications to [onEvent].
///
/// A malformed envelope is reported through [onMalformed] rather than thrown:
/// notifications have no reply channel, so throwing here would tear down the
/// peer over one bad frame.
void registerEventSink(
  json_rpc.Peer peer, {
  required void Function(EventEnvelope envelope) onEvent,
  void Function(Object error, StackTrace stack)? onMalformed,
}) {
  peer.registerMethod(kEventNotification, (json_rpc.Parameters params) {
    try {
      onEvent(EventEnvelope.fromJson(paramsToMap(params)));
    } catch (error, stack) {
      onMalformed?.call(error, stack);
    }
  });
}
