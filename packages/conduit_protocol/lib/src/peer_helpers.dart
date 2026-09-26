import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;

import 'events.dart';
import 'rpc_error.dart';

/// Decodes a method's parameter map into its DTO.
typedef ParamsDecoder<P> = P Function(Map<String, dynamic> json);

/// Encodes a method's result DTO into a JSON map.
typedef ResultEncoder<R> = Map<String, dynamic> Function(R result);

/// Normalizes `json_rpc_2`'s [json_rpc.Parameters] into a plain map.
///
/// The spec allows params to be absent or a list; every Conduit method takes a
/// named map, so anything else becomes an empty map and the DTO decoder
/// produces the real "missing required field" error. That keeps the failure
/// message about the field the caller forgot rather than about the shape.
Map<String, dynamic> paramsToMap(json_rpc.Parameters params) {
  final value = params.value;
  return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
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

/// Registers a method that takes no parameters.
void registerTypedMethodNoParams<R>(
  json_rpc.Peer peer,
  String name, {
  required ResultEncoder<R> encodeResult,
  required FutureOr<R> Function() handler,
}) => registerTypedMethod<void, R>(
  peer,
  name,
  decodeParams: (_) {},
  encodeResult: encodeResult,
  handler: (_) => handler(),
);

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
