import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:json_rpc_2/error_code.dart' as json_rpc_codes;
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;

part 'rpc_error.freezed.dart';
part 'rpc_error.g.dart';

/// The single JSON-RPC error code Conduit uses for application failures.
///
/// JSON-RPC 2.0 reserves -32768..-32000 for implementation-defined server
/// errors. Every Conduit failure rides on this one code and carries the real,
/// stable identifier in [RpcError.code] so the UI can localize it.
const int kConduitRpcErrorCode = -32000;

/// A failure crossing the daemon/UI boundary.
///
/// Errors travel as `{code, args}` rather than as prose. The daemon has no
/// locale and no access to the ARB catalog; the UI looks [code] up in its
/// localizations and interpolates [args]. This is what lets `api_service.dart`
/// drop its `current_localizations` import (WP-1.6).
/// Implements [Exception] so a handler can `throw RpcError(...)` directly;
/// [registerTypedMethod] converts it to the wire form on the way out.
@freezed
abstract class RpcError with _$RpcError implements Exception {
  const factory RpcError({
    /// Stable machine identifier, e.g. `auth.invalidCredentials`.
    ///
    /// Use the constants in [ConduitErrorCodes]; a literal here is a bug
    /// waiting for a typo.
    required String code,

    /// Placeholder values for the localized message, e.g. `{'status': '503'}`.
    ///
    /// Stringly-typed on purpose: these are interpolated into ARB placeholders,
    /// and keeping them strings means the daemon never has to guess how a
    /// locale wants a number or date formatted.
    @Default(<String, String>{}) Map<String, String> args,

    /// Developer-facing detail for the diagnostics log. Never rendered to the
    /// user, never localized, and safe to omit in release builds.
    String? debugMessage,

    /// Whether retrying the same request could plausibly succeed. Drives the
    /// "Retry" affordance without the UI having to pattern-match on [code].
    @Default(false) bool retryable,
  }) = _RpcError;

  const RpcError._();

  /// Note: `RpcException.serialize` injects a `request` key into `data` when
  /// the payload is a map that lacks one, so the decoded JSON carries one more
  /// field than [toJson] wrote. Unrecognized keys are ignored by design —
  /// never turn on `disallowUnrecognizedKeys` here.
  factory RpcError.fromJson(Map<String, dynamic> json) =>
      _$RpcErrorFromJson(json);

  /// Rebuilds an [RpcError] from a `json_rpc_2` exception thrown by a peer.
  ///
  /// Anything that did not originate from [toException] — a transport fault, a
  /// malformed frame, a method the peer does not implement — is mapped to a
  /// generic code so callers never have to handle a null.
  factory RpcError.fromException(Object error) {
    if (error is json_rpc.RpcException) {
      final data = error.data;
      if (error.code == kConduitRpcErrorCode && data is Map) {
        return RpcError.fromJson(Map<String, dynamic>.from(data));
      }
      return RpcError(
        code: switch (error.code) {
          json_rpc_codes.METHOD_NOT_FOUND => ConduitErrorCodes.methodNotFound,
          json_rpc_codes.INVALID_PARAMS => ConduitErrorCodes.invalidParams,
          json_rpc_codes.PARSE_ERROR ||
          json_rpc_codes.INVALID_REQUEST => ConduitErrorCodes.protocolViolation,
          _ => ConduitErrorCodes.internal,
        },
        debugMessage: error.message,
      );
    }
    return RpcError(
      code: ConduitErrorCodes.internal,
      debugMessage: error.toString(),
    );
  }

  /// Wraps this error for the wire. The payload lands in the JSON-RPC `data`
  /// field, which is the only part of the envelope we control.
  json_rpc.RpcException toException() => json_rpc.RpcException(
    kConduitRpcErrorCode,
    // `message` is required by the spec and shows up in raw transport logs.
    // The UI ignores it; it reads `code` out of `data`.
    debugMessage ?? code,
    data: toJson(),
  );
}

/// Stable error identifiers. The UI maps each to an ARB key.
///
/// Codes are namespaced by the RPC family that raises them so a new family can
/// add codes without coordinating with anyone.
abstract final class ConduitErrorCodes {
  // Transport / protocol.
  static const String internal = 'rpc.internal';
  static const String methodNotFound = 'rpc.methodNotFound';
  static const String invalidParams = 'rpc.invalidParams';
  static const String protocolViolation = 'rpc.protocolViolation';
  static const String protocolVersionMismatch = 'rpc.protocolVersionMismatch';
  static const String unauthorized = 'rpc.unauthorized';
  static const String timeout = 'rpc.timeout';
  static const String cancelled = 'rpc.cancelled';
  static const String daemonUnavailable = 'rpc.daemonUnavailable';
  static const String shuttingDown = 'rpc.shuttingDown';

  // Network / server.
  static const String offline = 'net.offline';
  static const String connectionFailed = 'net.connectionFailed';
  static const String tlsUntrusted = 'net.tlsUntrusted';
  static const String serverError = 'net.serverError';

  // Auth.
  static const String unauthenticated = 'auth.unauthenticated';
  static const String invalidCredentials = 'auth.invalidCredentials';
  static const String sessionExpired = 'auth.sessionExpired';

  // Placeholder families. Filled in as each milestone lands its methods; the
  // constants exist now so handlers can be written against them.
  static const String notFound = 'resource.notFound';
  static const String conflict = 'resource.conflict';
  static const String unsupported = 'capability.unsupported';
}
