import 'package:meta/meta.dart';

/// Why a request failed, in a form the core can produce without a locale.
///
/// The core has no `AppLocalizations` and, once it is hosted by `conduitd`,
/// no way to get one — the daemon serves several windows that may not even
/// share a language. So it classifies the failure and lets each front-end
/// render it.
///
/// An enum rather than a string: the Flutter resolver switches over it
/// exhaustively, so adding a code without localizing it is a compile error
/// instead of a mystery blank in some locale. `.name` is what crosses the RPC
/// boundary as `RpcError.code`.
enum CoreErrorCode {
  /// Nothing more specific is known.
  generic,

  // Network.
  networkGeneric,
  networkTimeout,
  requestTimedOut,
  checkConnection,

  // Server.
  serverGeneric,
  serverInternal,
  serverUnavailable,
  serverTimeout,

  // Auth.
  authSessionExpired,
  authForbidden,

  // Client.
  validationGeneric,
  fileNotFound,
  securityCertificate,

  // Rate limiting.
  rateLimitExceeded,
  rateLimitRetrySoon,

  /// Carries `delay` in [ErrorMessage.args], already formatted for display.
  rateLimitRetryAfter,
}

/// A localizable message: a [CoreErrorCode] plus its placeholder values.
///
/// [args] are strings because they are interpolated into ARB placeholders,
/// and the core must not decide how a locale formats a number or a duration.
@immutable
class ErrorMessage {
  const ErrorMessage(this.code, {this.args = const <String, String>{}});

  final CoreErrorCode code;
  final Map<String, String> args;

  /// The wire form, matching `conduit_protocol`'s `RpcError`.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'code': code.name,
    if (args.isNotEmpty) 'args': args,
  };

  @override
  bool operator ==(Object other) =>
      other is ErrorMessage &&
      other.code == code &&
      _mapEquals(other.args, args);

  @override
  int get hashCode => Object.hash(
    code,
    Object.hashAllUnordered(
      args.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  @override
  String toString() => args.isEmpty
      ? 'ErrorMessage(${code.name})'
      : 'ErrorMessage(${code.name}, $args)';

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
