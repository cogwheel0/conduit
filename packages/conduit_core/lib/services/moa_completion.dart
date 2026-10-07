import 'dart:async';

import 'openwebui_stream_parser.dart';

/// A merged-response completion in flight: the server's streamed text, parsed
/// with the same SSE reader chat completions use, and a way to stop it.
final class MoaCompletion {
  const MoaCompletion({required this.updates, required this.cancel});

  final Stream<OpenWebUIStreamUpdate> updates;

  /// Stops the request. Whatever text already arrived stays with the caller.
  final Future<void> Function() cancel;
}

/// The server has no merge endpoint (or does not let this account use it).
/// Nothing was generated and no ordinary chat request stands in for it.
final class MoaCompletionUnavailable implements Exception {
  const MoaCompletionUnavailable(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'MoaCompletionUnavailable($statusCode)';
}

/// The server accepted the merge request path but refused or failed the merge.
final class MoaCompletionFailed implements Exception {
  const MoaCompletionFailed(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'MoaCompletionFailed($statusCode): $message';
}
